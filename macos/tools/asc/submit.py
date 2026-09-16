#!/usr/bin/env python3
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
"""

from __future__ import annotations

import argparse
import sys
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


def run_submit(platform: str, confirm: bool) -> int:
    version = latest_version(platform)
    if version is None:
        print(f"{platform}: no version to submit")
        return 1
    sub = submission_for(submissions(), platform)
    items = items_of(sub["id"]) if sub else []
    steps = next_steps(sub, platform, version["id"], items)
    label = f"{platform} {version['attributes']['versionString']} ({version['attributes'].get('appVersionState') or version['attributes'].get('appStoreState')})"
    print(f"{label} · submission {sub['id'][:8] + ' ' + sub['attributes']['state'] if sub else 'none'}")
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
                bail("add item", resp)  # exits: the submission stays READY_FOR_REVIEW, re-run to resume
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("status")
    st.add_argument("--platform", choices=PLATFORMS)
    for name in ("submit", "cancel"):
        p = sub.add_parser(name)
        p.add_argument("--platform", choices=PLATFORMS, required=True)
        p.add_argument("--confirm", action="store_true")
    args = ap.parse_args()
    if args.cmd == "status":
        return run_status((args.platform,) if args.platform else PLATFORMS)
    if args.cmd == "submit":
        return run_submit(args.platform, args.confirm)
    return run_cancel(args.platform, args.confirm)


if __name__ == "__main__":
    sys.exit(main())
