#!/usr/bin/env -S uv run --script --managed-python
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Which Xcode Cloud build carries a commit, and is it ready to ship.

  builds.py wait [--commit SHA] [--timeout 3600]   wait for the run that built SHA (default: the
                                                   newest release tag's commit), then for its Mac +
                                                   iOS builds to process VALID; prints the build number
  builds.py status --build N                       processing state per platform

Why: on 2026-10-04/05 this loop was hand-written four times (448, 450, 452, 453). Two merges
seconds apart make Xcode Cloud cancel the first run; the next run carries both, so a
canceled run for your commit means "look at the next one", not "failed". Read-only.

Signed: Kev + claude-opus-5-5, 2026-10-05, Confidence 0.85, Prior: Unknown. The pure half
is pinned in test_builds.py; the API shapes are the ones the 2026-10-05 release polled live.
Review: Kev + claude-opus-5-5, 2026-10-17 — Xcode Cloud starts only on `release*` tags now (the
month's compute ran out building every master push). `wait` defaults to the newest release tag,
and a commit no release tag points at stops at once with the command that cuts one, instead of
waiting an hour for a run that will never start. Confidence 0.85.
Review: Kev + claude-opus-5-5, 2026-10-17 (#637) — `--commit` resolves to a full sha (a short one read as
untagged), and a failed tag fetch is an error, not a stale local list. Confidence 0.85.
"""
from __future__ import annotations

import argparse
import sys
import time
from typing import Any

from asc import APP_ID, call
from release_tag import PREFIX, RELEASE_TAGS, git, remote_release_tags_at
from submit import SHIPPING_PLATFORMS

# --------------------------------------------------------------------------- #
# Pure (unit-pinned)
# --------------------------------------------------------------------------- #


def run_for_commit(runs: list[dict[str, Any]], sha: str) -> dict[str, Any] | None:
    if not sha:
        return None  # an empty sha would prefix-match every run
    for run in runs:
        built = ((run["attributes"].get("sourceCommit") or {}).get("commitSha") or "")
        if built and (built.startswith(sha) or sha.startswith(built)):
            return run
    return None


def run_outcome(run: dict[str, Any]) -> str:
    a = run["attributes"]
    if a.get("executionProgress") != "COMPLETE":
        return "running"
    return (a.get("completionStatus") or "unknown").lower()


def ready(states: dict[str, str], platforms: tuple[str, ...]) -> bool:
    return all(states.get(p) == "VALID" for p in platforms)


# --------------------------------------------------------------------------- #
# Effectful
# --------------------------------------------------------------------------- #


def checked(resp: dict[str, Any], what: str) -> dict[str, Any]:
    """An ASC error must not read as "no run yet" / "not uploaded": exit 4, like pr_watch."""
    if "_error" in resp:
        print(f"ASC error on {what}: {resp['_error']} {str(resp.get('_body', ''))[:200]}", flush=True)
        sys.exit(4)
    return resp


def product_id() -> str:
    resp = checked(call("GET", "/v1/ciProducts", params={"limit": 20}), "ciProducts")
    ids = [p["id"] for p in resp.get("data", []) if p["attributes"].get("name") == "M1K3"]
    if not ids:
        print("no Xcode Cloud product named M1K3", flush=True)
        sys.exit(4)
    return ids[0]


def recent_runs(pid: str) -> list[dict[str, Any]]:
    return checked(call("GET", f"/v1/ciProducts/{pid}/buildRuns", params={"limit": 10, "sort": "-number"}),
                   "buildRuns").get("data", [])


def build_states(number: str, platforms: tuple[str, ...]) -> dict[str, str]:
    states = {}
    for p in platforms:
        data = checked(call("GET", "/v1/builds", params={"filter[app]": APP_ID, "filter[version]": number,
                                                         "filter[preReleaseVersion.platform]": p, "limit": 1}),
                       "builds").get("data", [])
        states[p] = data[0]["attributes"]["processingState"] if data else "not uploaded"
    return states


def resolve_commit(arg: str) -> str:
    """The full sha for a commit-ish ("" if it isn't one): ls-remote holds full oids (#637)."""
    out = git("rev-parse", "--verify", "--end-of-options", f"{arg}^{{commit}}")
    return out.stdout.strip() if out.returncode == 0 else ""


def latest_release() -> tuple[str, str] | None:
    """(tag, commit) of the newest release tag on origin, ("", "") when there is none, or None
    when origin couldn't be read (a stale local list could name an old release, #637)."""
    if git("fetch", "-q", "origin", RELEASE_TAGS).returncode != 0:
        return None
    tags = git("tag", "--list", f"{PREFIX}*", "--sort=-creatordate").stdout.split()
    if not tags:
        return "", ""
    peeled = git("rev-list", "-n", "1", tags[0])
    return (tags[0], peeled.stdout.strip()) if peeled.returncode == 0 else None


def run_wait(commit: str, timeout: int) -> int:
    pid = product_id()
    # Xcode Cloud starts only on release tags: an untagged commit never gets a run.
    if run_for_commit(recent_runs(pid), commit) is None:
        tags = remote_release_tags_at(commit)
        if tags is None:
            print("could not read release tags from origin", flush=True)
            return 4
        if not tags:
            print(f"commit {commit[:8]}: no release tag points at it, so Xcode Cloud will not build it."
                  f" Cut one: ./release_tag.py cut --commit {commit} --confirm", flush=True)
            return 4
    deadline = time.monotonic() + timeout
    last = ""
    while True:
        run = run_for_commit(recent_runs(pid), commit)
        line = f"commit {commit[:8]}: " + ("no run yet" if run is None else
                                            f"run {run['attributes']['number']} {run_outcome(run)}")
        if run is not None and run_outcome(run) == "succeeded":
            number = str(run["attributes"]["number"])
            states = build_states(number, SHIPPING_PLATFORMS)
            line += f" · builds {states}"
            if ready(states, SHIPPING_PLATFORMS):
                print(line, flush=True)
                print(f"build {number} is VALID on {' + '.join(SHIPPING_PLATFORMS)}", flush=True)
                return 0
        elif run is not None and run_outcome(run) != "running":
            print(line + " — a later run may carry this commit; wait on the newest commit instead", flush=True)
            return 1
        if line != last:
            print(line, flush=True)
            last = line
        if time.monotonic() >= deadline:
            print("timed out", flush=True)
            return 2
        time.sleep(60)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("wait")
    w.add_argument("--commit", default=None, help="default: the newest release tag's commit")
    w.add_argument("--timeout", type=int, default=3600)
    s = sub.add_parser("status")
    s.add_argument("--build", required=True)
    args = ap.parse_args()
    if args.cmd == "status":
        for platform, state in build_states(args.build, SHIPPING_PLATFORMS).items():
            print(f"{platform} build {args.build}: {state}")
        return 0
    if args.commit:
        tag, commit = "", resolve_commit(args.commit)
        if not commit:
            print(f"no such commit: {args.commit}", flush=True)
            return 4
    else:
        newest = latest_release()
        if newest is None:
            print("could not fetch release tags from origin; pass --commit SHA", flush=True)
            return 4
        tag, commit = newest
    if not commit:
        print("no release tag yet: cut one with ./release_tag.py cut --confirm", flush=True)
        return 4
    if tag:
        print(f"waiting on {tag}", flush=True)
    return run_wait(commit, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
