#!/usr/bin/env python3
"""Cut a release: tag a green master commit so Xcode Cloud builds it for TestFlight.

  release_tag.py cut [--commit SHA] [--why REASON] [--confirm]   tag + push (dry run without --confirm)
  release_tag.py list                                             the newest release tags

Why: since 2026-10-17 the Xcode Cloud `Release` workflow starts ONLY on tags beginning with
`release`. It used to start on every push to master, and with several merges a day archiving Mac
and iOS each time, the month's compute hours ran out by the 15th (every later run was cancelled
before a VM started). Master merges are now free; a TestFlight build is a deliberate act.

The tag names the version, the day and the commit: `release-1.1.0-20261017-07b1cabe`. It is cut
only on a commit that is on origin/master and whose GitHub `CI` run concluded success (`--why`
overrides a red or unfinished CI, never "not on master"). A commit already carrying a release tag
ON ORIGIN is not tagged again (a failed push deletes its local tag). The version is read from
project.yml at the tagged commit; the day is UTC. After a push, `./builds.py wait` (default: the
newest release tag) waits for the build. Cutting a release is Kev's call; the dry run shows
what would be pushed.

Signed: Kev + claude-opus-5-5, 2026-10-17, Confidence 0.85. Prior: none (new file).
Review: Kev + claude-opus-5-5, 2026-10-17 (#637 + review fold) — an unreadable origin is an error, not "no tag"; tests pin cut()'s failed-push cleanup and the dry run; docstring rewrapped.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path

PREFIX = "release"
# Only the release tags: `--tags` fails the whole fetch on any unrelated local tag that clashes
# with the remote's ("would clobber existing tag", seen on 2026.09.11).
RELEASE_TAGS = f"+refs/tags/{PREFIX}*:refs/tags/{PREFIX}*"
HERE = Path(__file__).resolve().parent
PROJECT_YML = "macos/project.yml"  # read AT the tagged commit, never from this checkout

# --------------------------------------------------------------------------- #
# Pure (unit-pinned)
# --------------------------------------------------------------------------- #


def tag_name(version: str, day: dt.date, sha: str) -> str:
    return f"{PREFIX}-{version}-{day:%Y%m%d}-{sha[:8]}"


def marketing_version(project_yml: str) -> str | None:
    match = re.search(r'MARKETING_VERSION:\s*"?([0-9][0-9A-Za-z.\-]*)"?', project_yml)
    return match.group(1) if match else None


def release_tags_in(ls_remote: str, sha: str) -> list[str]:
    """The release tags in `git ls-remote --tags` output that point at `sha`. An annotated tag's
    own id is not the commit: its `^{}` line is. A lightweight tag has none: its id is the commit."""
    peeled: dict[str, str] = {}
    direct: dict[str, str] = {}
    for line in ls_remote.splitlines():
        oid, _, ref = line.partition("\t")
        name = ref.removeprefix("refs/tags/")
        if name.endswith("^{}"):
            peeled[name[:-3]] = oid
        elif name:
            direct[name] = oid
    return sorted(name for name, oid in direct.items() if peeled.get(name, oid) == sha)


def plan(on_master: bool, ci: str | None, existing: list[str], why: str | None) -> tuple[bool, int, str]:
    """(cut it?, exit code, the reason when not)."""
    if not on_master:
        return False, 3, "not on origin/master: only merged code ships (land the PR first)"
    if existing:
        return False, 0, f"already tagged {', '.join(existing)}: Xcode Cloud built (or is building) it"
    if ci != "success" and not why:
        return False, 4, f"GitHub CI on this commit is {ci or 'missing'}, not success (pass --why to override)"
    return True, 0, ""


# --------------------------------------------------------------------------- #
# git / gh
# --------------------------------------------------------------------------- #


def git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], cwd=HERE, capture_output=True, text=True, check=False)


def remote_release_tags_at(sha: str) -> list[str] | None:
    """What origin holds, not this clone: a tag whose push failed must not read as shipped.
    None when origin can't be read (an error is not "no tag": that would invite a duplicate cut)."""
    out = git("ls-remote", "--tags", "origin", f"refs/tags/{PREFIX}*")
    return release_tags_in(out.stdout, sha) if out.returncode == 0 else None


def ci_conclusion(sha: str) -> str | None:
    # The master push run: a ff/rebase merge's PR run shares the sha. A superseded older master
    # commit reads `cancelled` (ci.yml cancels in progress), so cutting one needs --why.
    try:
        out = subprocess.run(
            ["gh", "run", "list", "--commit", sha, "--workflow", "ci.yml", "--event", "push",
             "--branch", "master", "--json", "status,conclusion", "--limit", "1"],
            cwd=HERE, capture_output=True, text=True, check=False,
        )
    except FileNotFoundError:
        print("gh is not installed: CI can't be read", flush=True)
        return None
    if out.returncode != 0:
        print(f"gh: {out.stderr.strip()}", flush=True)
        return None
    try:
        runs = json.loads(out.stdout or "[]")
    except json.JSONDecodeError:
        return None
    if not runs:
        return None
    run = runs[0]
    return run.get("conclusion") or run.get("status")


def cut(commit: str | None, why: str | None, confirm: bool) -> int:
    if git("fetch", "-q", "origin", "master", RELEASE_TAGS).returncode != 0:
        print("could not fetch origin", flush=True)
        return 2
    resolved = git("rev-parse", "--verify", "--end-of-options", f"{commit or 'origin/master'}^{{commit}}")
    sha = resolved.stdout.strip()
    if resolved.returncode != 0 or not sha:
        print(f"no such commit: {commit}", flush=True)
        return 2
    on_master = git("merge-base", "--is-ancestor", sha, "origin/master").returncode == 0
    existing = remote_release_tags_at(sha)
    if existing is None:
        print("could not read release tags from origin", flush=True)
        return 2
    ci = ci_conclusion(sha)
    ok, code, reason = plan(on_master, ci, existing, why)
    if not ok:
        print(f"{sha[:8]}: {reason}", flush=True)
        return code
    version = marketing_version(git("show", f"{sha}:{PROJECT_YML}").stdout)
    if not version:
        print(f"no MARKETING_VERSION in {PROJECT_YML} at {sha[:8]}", flush=True)
        return 2
    # The UTC day (near midnight in Ireland it can be the next or previous one).
    tag = tag_name(version, dt.datetime.now(dt.timezone.utc).date(), sha)
    subject = git("log", "-1", "--format=%s", sha).stdout.strip()
    note = f"M1K3 {version} for TestFlight (Xcode Cloud Release)\n\n{subject}" + (f"\n\nCI override: {why}" if ci != "success" else "")
    print(f"{tag} → {sha[:8]} {subject}", flush=True)
    print(f"  CI: {ci}" + (f" (override: {why})" if ci != "success" else ""), flush=True)
    if not confirm:
        print("dry run: pass --confirm to tag and push (this starts an Xcode Cloud build)", flush=True)
        return 0
    made = git("tag", "-a", tag, sha, "-m", note)
    if made.returncode != 0:
        print(f"could not create {tag}: {made.stderr.strip()}", flush=True)
        return 2
    pushed = git("push", "origin", tag)
    if pushed.returncode != 0:
        git("tag", "-d", tag)  # no local-only tag left behind to read as shipped next time
        print(f"push failed, local tag removed: {pushed.stderr.strip()}", flush=True)
        return 2
    print(f"pushed {tag}; next: ./builds.py wait --commit {sha}", flush=True)
    return 0


def list_tags() -> int:
    git("fetch", "-q", "origin", RELEASE_TAGS)
    out = git("tag", "--list", f"{PREFIX}*", "--sort=-creatordate", "--format=%(refname:short)  %(creatordate:short)")
    print("\n".join(out.stdout.splitlines()[:10]) or "no release tags yet", flush=True)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("cut")
    c.add_argument("--commit", default=None, help="default: origin/master")
    c.add_argument("--why", default=None, help="ship despite CI that is not green, and say why")
    c.add_argument("--confirm", action="store_true", help="tag and push (default: dry run)")
    sub.add_parser("list")
    args = ap.parse_args()
    if args.cmd == "list":
        return list_tags()
    return cut(args.commit, args.why, args.confirm)


if __name__ == "__main__":
    sys.exit(main())
