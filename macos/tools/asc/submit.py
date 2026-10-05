#!/usr/bin/env -S uv run --script --managed-python
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Review submissions — status / submit / cancel per platform, from the API.

Why: launch day (2026-09-15) drove this by hand from a scratchpad script that died with
its session; the 2026-09-16 network.server round needed the same PATCH again as a
one-liner. The state machine, once, with the shapes the launch day proved:

  status                          every submission per platform, newest first, with items
  submit --platform P [--confirm] create a submission if none is live → add the platform's
                                  newest version as its item if missing → submitted:true.
                                  A queued one (WAITING_FOR_REVIEW / IN_REVIEW) is nothing
                                  to do. Dry-run prints the plan without --confirm.
  cancel --platform P [--confirm] canceled:true on the live submission (CANCELING →
                                  COMPLETE; the version reads DEVELOPER_REJECTED, then
                                  editable). The queue position is the price.

A rejected version is re-added by ASC when it goes READY_FOR_REVIEW, or by `submit`
here; either way nothing moves until submitted:true — READY_FOR_REVIEW on the version
with UNRESOLVED_ISSUES on the submission is "prepared, not sent" (2026-09-16).

Signed: Kev + claude-fable-5.1, 2026-09-16, Confidence 0.8 (the pure state machine is
pytest-pinned; every payload shape is the one launch day and the 09-16 resubmit drove
live; `submit --confirm` / `cancel --confirm` are verify-by-run — ASC writes are Kev's
to run). Prior: Unknown.
Review: Kev + claude-opus-5-5, 2026-10-05 — `attach` (a build onto an editable version, read
back), `--platform ALL` (Mac + iOS), `cancel --wait`, and the submit gate: `--confirm` refuses
a build verify_build.py hasn't stamped, unless `--why`. All four were scratchpad code during the
2026-10-05 release, where both cancels and the submit ran before the build was checked. PEP 723
header so `./submit.py` brings its own deps. Confidence 0.85 (pure half pinned; attach and
cancel were driven live on 2026-10-05 through the scratchpad versions of this code).
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path
from typing import Any

from asc import APP_ID, PLATFORMS, bail, call, paginate
from precheck import latest_version  # no cycle: precheck never imports submit

# Submission states. (READY_FOR_REVIEW is ALSO a version state — precheck.SUBMITTABLE_STATES —
# the same string on two resources: here it means "an item is prepared, nothing sent".)
LIVE_STATES = ("READY_FOR_REVIEW", "UNRESOLVED_ISSUES", "WAITING_FOR_REVIEW", "IN_REVIEW")
QUEUED_STATES = ("WAITING_FOR_REVIEW", "IN_REVIEW")
# Transitional: a cancel in flight. Not live (nothing to cancel or submit), not gone either —
# creating a second submission beside it is the one thing `submit` must not do.
WAITING_STATES = ("CANCELING",)
# Version states where the build can change: before a first submit, and after a cancel or rejection.
EDITABLE_STATES = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")
# What `--platform ALL` means: the platforms that ship a build. visionOS has a version, never a build.
SHIPPING_PLATFORMS = ("MAC_OS", "IOS")
# verify_build.py stamps a build here once it has run on this Mac; `submit` reads it.
STAMP_DIR = Path("~/.cache/m1k3-release").expanduser()
MIN_WHY = 10  # a reason, not a token


# --------------------------------------------------------------------------- #
# Pure (unit-pinned)
# --------------------------------------------------------------------------- #


def submission_for(subs: list[dict[str, Any]], platform: str) -> dict[str, Any] | None:
    """The one live submission for `platform` (ASC allows one at a time); terminal
    states (COMPLETE, CANCELING, …) never count, however new."""
    live = [
        s for s in subs
        if s["attributes"].get("platform") == platform
        and s["attributes"].get("state") in LIVE_STATES + WAITING_STATES
    ]
    live.sort(key=lambda s: s["attributes"].get("submittedDate") or "", reverse=True)
    return live[0] if live else None


def has_item(items: list[dict[str, Any]], version_id: str) -> bool:
    return any(
        (((i.get("relationships") or {}).get("appStoreVersion") or {}).get("data") or {}).get("id") == version_id
        for i in items
    )


def next_steps(
    submission: dict[str, Any] | None, platform: str, version_id: str, items: list[dict[str, Any]]
) -> list[str]:
    """What `submit` would do, as words — the dry-run output and the plan it executes."""
    if submission is not None and submission["attributes"]["state"] in QUEUED_STATES:
        return [f"already {submission['attributes']['state']} — nothing to do"]
    if submission is not None and submission["attributes"]["state"] in WAITING_STATES:
        return [f"{submission['attributes']['state']} — wait for COMPLETE, then submit again"]
    steps = []
    if submission is None:
        steps.append(f"create a {platform} submission")
    if submission is None or not has_item(items, version_id):
        steps.append(f"add version {version_id}")
    steps.append("submit")
    return steps


def cancel_allowed(submission: dict[str, Any] | None) -> bool:
    return submission is not None and submission["attributes"].get("state") in LIVE_STATES


def expand_platforms(arg: str) -> tuple[str, ...]:
    return SHIPPING_PLATFORMS if arg == "ALL" else (arg,)


def is_editable(version_state: str | None) -> bool:
    return version_state in EDITABLE_STATES


def already_attached(build: dict[str, Any] | None, current: str | None) -> bool:
    return build is not None and current == build["attributes"]["version"]


def attach_problems(version_state: str | None, build: dict[str, Any] | None, current: str | None) -> list[str]:
    """Why `attach` must not run; empty means go. The 2026-10-05 scratchpad script's checks."""
    if build is None:
        return ["no such build for this platform"]
    a = build["attributes"]
    problems = []
    if not is_editable(version_state):
        problems.append(f"version is {version_state}, not editable (cancel the submission first)")
    if a.get("processingState") != "VALID" or a.get("expired"):
        problems.append(f"build is {a.get('processingState')}, expired={a.get('expired')}")
    if a.get("usesNonExemptEncryption") is None:
        problems.append("export compliance not answered on the build")
    return problems


def blocked(gates: dict[str, list[str]]) -> list[str]:
    """Every platform's refusal, prefixed; empty means all may go. `submit --platform ALL`
    writes nothing unless this is empty, so a release is never half-sent."""
    return [f"{platform}: {problem}" for platform, problems in gates.items() for problem in problems]


def attach_payload(build_id: str) -> dict[str, Any]:
    return {"data": {"type": "builds", "id": build_id}}


def gate_problems(build: str | None, stamp_dir: Path = STAMP_DIR, why: str | None = None) -> list[str]:
    """`submit` sends a build to Apple only once it ran on this Mac (verify_build.py stamps it),
    or with a stated reason. On 2026-10-05 both cancels and the submit ran before any check."""
    if not build:
        return ["no build attached to the version: run `attach --build N` first"]
    if why and len(why.strip()) >= MIN_WHY:
        return []
    if (stamp_dir / f"verified-{build}.json").exists():
        return []
    return [(f"build {build} has not been verified on this Mac: run verify_build.py --build {build}, "
             f"or pass --why \"<reason, {MIN_WHY}+ chars>\"")]


def create_payload(platform: str) -> dict[str, Any]:
    return {
        "data": {
            "type": "reviewSubmissions",
            "attributes": {"platform": platform},
            "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}},
        }
    }


def item_payload(submission_id: str, version_id: str) -> dict[str, Any]:
    return {
        "data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission_id}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
            },
        }
    }


def submit_payload(submission_id: str) -> dict[str, Any]:
    return {"data": {"type": "reviewSubmissions", "id": submission_id, "attributes": {"submitted": True}}}


def cancel_payload(submission_id: str) -> dict[str, Any]:
    return {"data": {"type": "reviewSubmissions", "id": submission_id, "attributes": {"canceled": True}}}


# --------------------------------------------------------------------------- #
# Effectful
# --------------------------------------------------------------------------- #


def submissions() -> list[dict[str, Any]]:
    return list(paginate(f"/v1/reviewSubmissions?filter[app]={APP_ID}&limit=50"))


def items_of(submission_id: str) -> list[dict[str, Any]]:
    """`include=appStoreVersion` is what makes the item carry its version relationship —
    the bare list returns items with no relationships at all (probed 2026-09-16), and
    `has_item` would read every version as missing."""
    return list(paginate(f"/v1/reviewSubmissions/{submission_id}/items?include=appStoreVersion&limit=50"))


def run_status(platforms: tuple[str, ...]) -> int:
    subs = submissions()
    for platform in platforms:
        rows = [s for s in subs if s["attributes"].get("platform") == platform]
        rows.sort(key=lambda s: s["attributes"].get("submittedDate") or "", reverse=True)
        print(f"== {platform}: {len(rows)} submission(s)")
        for s in rows[:6]:
            a = s["attributes"]
            versions = ", ".join(
                (i.get("relationships", {}).get("appStoreVersion", {}).get("data") or {}).get("id", "?")[:8]
                for i in items_of(s["id"])
            ) if a.get("state") in LIVE_STATES else "…"
            print(f"   {s['id'][:8]} {a.get('state'):<20} {a.get('submittedDate') or '-':<26} items: {versions}")
    return 0


def submitted_build(version: dict[str, Any]) -> str | None:
    return ((version.get("_build") or {}).get("attributes") or {}).get("version")


def run_submit(platform: str, confirm: bool, why: str | None = None) -> int:
    version = latest_version(platform)
    if version is None:
        print(f"{platform}: no version to submit")
        return 1
    sub = submission_for(submissions(), platform)
    items = items_of(sub["id"]) if sub else []
    steps = next_steps(sub, platform, version["id"], items)
    label = f"{platform} {version['attributes']['versionString']} ({version['attributes'].get('appVersionState') or version['attributes'].get('appStoreState')})"
    print(f"{label} · submission {sub['id'][:8] + ' ' + sub['attributes']['state'] if sub else 'none'}")
    build = submitted_build(version)
    gate = gate_problems(build, why=why)
    if gate:
        print(f"{platform}: {'refusing' if confirm else 'dry-run: submit --confirm would refuse'} — {gate[0]}")
        if confirm:
            return 5
    elif why and gate_problems(build):
        print(f"   gate bypassed: {why}")
    elif platform != "MAC_OS":
        print(f"   gate: build {build} verified by its Mac run (same build, same source); "
              f"the {platform} app itself is checked by hand on a device")
    for step in steps:
        print(f"   {step}")
    if steps[0].startswith("already") or steps[0].startswith("CANCELING"):
        return 0
    if not confirm:
        print("dry-run — add --confirm to execute")
        return 0
    sub_id = sub["id"] if sub else None
    for step in steps:
        if step.startswith("create"):
            resp = call("POST", "/v1/reviewSubmissions", json=create_payload(platform))
            if "_error" in resp:
                bail("create submission", resp)  # exits: nothing to clean up yet
            sub_id = resp["data"]["id"]
            print(f"   created {sub_id[:8]}")
        elif step.startswith("add version"):
            resp = call("POST", "/v1/reviewSubmissionItems", json=item_payload(sub_id, version["id"]))
            if "_error" in resp:
                bail("add item", resp)  # exits: the submission keeps its state, no item yet; re-run to resume
            print(f"   item {resp['data']['id'][:8]} added")
        elif step == "submit":
            resp = call("PATCH", f"/v1/reviewSubmissions/{sub_id}", json=submit_payload(sub_id))
            if "_error" in resp:
                bail("submit", resp)  # exits: item added, nothing sent, re-run to resume
            state = resp.get("data", {}).get("attributes", {}).get("state")
            print(f"   submitted → {state}")
            return 0 if state in QUEUED_STATES else 1
    return 0


def run_cancel(platform: str, confirm: bool) -> int:
    sub = submission_for(submissions(), platform)
    if not cancel_allowed(sub):
        print(f"{platform}: no live submission to cancel")
        return 1
    print(f"{platform}: submission {sub['id'][:8]} {sub['attributes']['state']} → canceled")
    if not confirm:
        print("dry-run — add --confirm to execute (the queue position is the price)")
        return 0
    resp = call("PATCH", f"/v1/reviewSubmissions/{sub['id']}", json=cancel_payload(sub["id"]))
    if "_error" in resp:
        bail("cancel", resp)
    print(f"   → {resp.get('data', {}).get('attributes', {}).get('state')}")
    return 0


def build_for(platform: str, number: str) -> dict[str, Any] | None:
    resp = call("GET", "/v1/builds", params={
        "filter[app]": APP_ID, "filter[version]": number,
        "filter[preReleaseVersion.platform]": platform, "limit": 1})
    data = [] if "_error" in resp else resp.get("data", [])
    return data[0] if data else None


def run_attach(platform: str, number: str, confirm: bool) -> int:
    version = latest_version(platform)
    if version is None:
        print(f"{platform}: no version")
        return 1
    state = version["attributes"].get("appStoreState")
    current = ((version.get("_build") or {}).get("attributes") or {}).get("version")
    build = build_for(platform, number)
    print(f"{platform} {version['attributes']['versionString']} [{state}]: build {current} -> {number}")
    if already_attached(build, current):
        print(f"   already on build {number} — nothing to do")
        return 0
    problems = attach_problems(state, build, current)
    if problems:
        print("   refusing:\n     " + "\n     ".join(problems))
        return 1
    if not confirm:
        print("   dry-run — add --confirm to attach")
        return 0
    resp = call("PATCH", f"/v1/appStoreVersions/{version['id']}/relationships/build", json=attach_payload(build["id"]))
    if "_error" in resp:
        bail("attach build", resp)
    after = ((latest_version(platform) or {}).get("_build") or {}).get("attributes", {}).get("version")
    if after != number:
        print(f"   read-back says build {after}, not {number}")
        return 1
    print(f"   attached: now carries build {after} (read back from the API)")
    return 0


def wait_editable(platform: str, timeout: int = 900) -> int:
    """A cancel is CANCELING for a while; the version only takes a new build once editable."""
    deadline = time.monotonic() + timeout
    while True:
        state = ((latest_version(platform) or {}).get("attributes") or {}).get("appStoreState")
        if is_editable(state):
            print(f"   {platform} version is {state}: editable")
            return 0
        if time.monotonic() >= deadline:
            print(f"   {platform} still {state} after {timeout}s")
            return 2
        time.sleep(20)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("status")
    st.add_argument("--platform", choices=PLATFORMS)
    for name in ("submit", "cancel", "attach"):
        p = sub.add_parser(name)
        p.add_argument("--platform", choices=PLATFORMS + ("ALL",), required=True,
                       help="ALL = " + " + ".join(SHIPPING_PLATFORMS))
        p.add_argument("--confirm", action="store_true")
    sub.choices["attach"].add_argument("--build", required=True, help="the build number, e.g. 453")
    sub.choices["cancel"].add_argument("--wait", action="store_true", help="wait until the version is editable")
    sub.choices["submit"].add_argument("--why", default=None,
                                       help="the reason to submit a build verify_build.py hasn't stamped")
    args = ap.parse_args()
    if args.cmd == "status":
        return run_status((args.platform,) if args.platform else PLATFORMS)
    platforms = expand_platforms(args.platform)
    if args.cmd == "submit" and args.confirm:
        gates = {}
        for platform in platforms:
            version = latest_version(platform)
            gates[platform] = (["no version to submit"] if version is None
                               else gate_problems(submitted_build(version), why=args.why))
        refusals = blocked(gates)
        if refusals:
            print("refusing — nothing sent to Apple:\n   " + "\n   ".join(refusals))
            return 5
    worst = 0
    cancelled = []
    for platform in platforms:
        if args.cmd == "submit":
            rc = run_submit(platform, args.confirm, args.why)
            if rc and args.confirm:
                return rc  # an API failure mid-release: stop, don't send the next platform
        elif args.cmd == "attach":
            rc = run_attach(platform, args.build, args.confirm)
        else:
            rc = run_cancel(platform, args.confirm)
            if rc == 0:
                cancelled.append(platform)
        worst = max(worst, rc)
    if args.cmd == "cancel" and args.confirm and args.wait:
        for platform in cancelled:  # cancel every platform first, then wait on each
            worst = max(worst, wait_editable(platform))
    return worst


if __name__ == "__main__":
    sys.exit(main())
