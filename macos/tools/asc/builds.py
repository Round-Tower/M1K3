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
  builds.py diagnose [--commit SHA]                does Xcode Cloud list the release tags at SHA?
                                                   (`wait` runs it once after --diagnose-after 300 s)

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
Review: Kev + claude-opus-5-5, 2026-10-17 (review fold) — an unreadable origin stops `wait` (4) instead of reading as
"no tag", and a failed peel of the newest tag reads as unreadable. Both pinned. Confidence 0.85.
Review: Kev + claude-opus-5.5, 2026-11-05 — a tag Xcode Cloud never received (release-1.3.0-20261105-63446054:
the Release workflow's repository listed 100 refs against origin's 101) now says so. After --diagnose-after
seconds of "no run yet", `wait` compares that workflow's own repository's gitReferences with the release tags
on origin at the commit, once, and prints the -r2 re-trigger command; it never pushes. The product's
primaryRepositories (a stale m1k3-private) is deliberately not read. Confidence 0.8: a 100-ref page may be a cap.
"""
from __future__ import annotations

import argparse
import re
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


def missed_tags(xcode_ref_names: list[str], tags_at_commit: list[str]) -> list[str]:
    """The tags at the commit that Xcode Cloud's repository doesn't list (bare or refs/tags/ names)."""
    known = {name.removeprefix("refs/tags/") for name in xcode_ref_names}
    return [tag for tag in tags_at_commit if tag not in known]


def ref_count(ls_remote: str) -> int:
    """Refs in `git ls-remote` output; an annotated tag's `^{}` line is the same ref, peeled."""
    return sum(1 for line in ls_remote.splitlines() if "\t" in line and not line.endswith("^{}"))


def retrigger_tag(missed: list[str]) -> tuple[str, str]:
    """(base tag, the next -rN past every missed one): a missed -r2 asks for -r3, never a collision."""

    def parsed(tag: str) -> tuple[str, int]:
        m = re.fullmatch(r"(.+)-r(\d+)", tag)
        return (m.group(1), int(m.group(2))) if m else (tag, 1)

    base, n = max((parsed(t) for t in missed), key=lambda bn: (bn[1], bn[0]))
    return base, f"{base}-r{n + 1}"


def format_diagnosis(missed: list[str], xcode_count: int, origin_count: int, sha: str,
                     known: list[str] | None = None) -> str:
    counts = f"Xcode Cloud lists {xcode_count} refs, origin has {origin_count}"
    cap = (" 100 is a round number: the API may cap the page, so a name missing past it is a hint, not proof."
           if xcode_count == 100 and missed else "")
    if known:
        line = (f"commit {sha[:8]}: Xcode Cloud knows {', '.join(known)}, so the delay is Xcode Cloud's own,"
                f" not a dropped push ({counts}).")
        if missed:
            line += (f" It does not list {', '.join(missed)} — that push never reached it, but a known tag"
                     f" did: wait on the run it starts.{cap}")
        return line
    if not missed:
        return f"commit {sha[:8]}: no release tag points at it on origin ({counts})."
    base, new = retrigger_tag(missed)
    return (f"commit {sha[:8]}: Xcode Cloud never received {', '.join(missed)}: {counts}.{cap}\n"
            f"Re-trigger it (Kev or Claude):\n"
            f'  git -C ~/Development/m1k3 tag -a {new} {sha} -m "re-trigger: Xcode Cloud missed {base}"'
            f" && git -C ~/Development/m1k3 push origin {new}\n"
            f"then `builds.py wait --commit {sha}` follows the new run.")


def diagnose_due(no_run_since: float | None, now: float, after: float, done: bool) -> bool:
    """Diagnose once, when the commit has had no run for `after` seconds (None: a run exists)."""
    return not done and no_run_since is not None and now - no_run_since >= after


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


def release_repository(pid: str) -> str | None:
    """The Release workflow's own repository id. Not the product's primaryRepositories: that one
    lists a stale m1k3-private (2026-11-05)."""
    flows = call("GET", f"/v1/ciProducts/{pid}/workflows", params={"limit": 50})
    ids = [w["id"] for w in flows.get("data", []) if w["attributes"].get("name") == "Release"]
    if "_error" in flows or not ids:
        return None
    repo = call("GET", f"/v1/ciWorkflows/{ids[0]}/repository")
    return None if "_error" in repo else (repo.get("data") or {}).get("id")


def xcode_ref_names(repo_id: str) -> list[str] | None:
    """Every live ref name Xcode Cloud lists for the repository, across `links.next` pages."""
    names: list[str] = []
    page: str | None = f"/v1/scmRepositories/{repo_id}/gitReferences?limit=200"
    while page:
        resp = call("GET", page)
        if "_error" in resp:
            return None
        names += [r["attributes"]["name"] for r in resp.get("data", []) if not r["attributes"].get("isDeleted")]
        page = resp.get("links", {}).get("next")
    return names


def origin_ref_count() -> int | None:
    out = git("ls-remote", "--heads", "--tags", "origin")
    return ref_count(out.stdout) if out.returncode == 0 else None


def diagnose_missed_tag(commit: str, pid: str | None = None) -> str:
    """Read-only: does Xcode Cloud list the release tags origin holds at `commit`? Never pushes."""
    repo = release_repository(pid or product_id())
    if repo is None:
        return "diagnosis: could not read the Release workflow's repository from ASC"
    names = xcode_ref_names(repo)
    if names is None:
        return f"diagnosis: could not read gitReferences for repository {repo}"
    tags = remote_release_tags_at(commit)
    origin = origin_ref_count()
    if tags is None or origin is None:
        return "diagnosis: could not read refs from origin"
    missed = missed_tags(names, tags)
    return format_diagnosis(missed, len(names), origin, commit, known=[t for t in tags if t not in missed])


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


def run_wait(commit: str, timeout: int, diagnose_after: int = 300) -> int:
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
    no_run_since: float | None = None
    diagnosed = False
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
        now = time.monotonic()
        no_run_since = (now if no_run_since is None else no_run_since) if run is None else None
        if diagnose_due(no_run_since, now, diagnose_after, diagnosed):
            print(diagnose_missed_tag(commit, pid), flush=True)  # once; then keep waiting
            diagnosed = True
        if now >= deadline:
            print("timed out", flush=True)
            return 2
        time.sleep(60)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("wait")
    w.add_argument("--commit", default=None, help="default: the newest release tag's commit")
    w.add_argument("--timeout", type=int, default=3600)
    w.add_argument("--diagnose-after", type=int, default=300,
                   help="seconds of 'no run yet' before checking, once, that Xcode Cloud received the tag")
    d = sub.add_parser("diagnose")
    d.add_argument("--commit", default=None, help="default: the newest release tag's commit")
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
    if args.cmd == "diagnose":
        print(diagnose_missed_tag(commit), flush=True)
        return 0
    if tag:
        print(f"waiting on {tag}", flush=True)
    return run_wait(commit, args.timeout, args.diagnose_after)


if __name__ == "__main__":
    sys.exit(main())
