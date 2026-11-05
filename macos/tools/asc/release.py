#!/usr/bin/env -S uv run --script --managed-python
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""The release runbook as one command: where a release stands, and the next line to run.

  release.py status [--tag TAG]   the tag and its commit, the Xcode Cloud run and build, each
                                  shipping platform's App Store version (state + attached build),
                                  the verify stamp, and every PR merged on origin/master after the
                                  tag (NOT in this build), docs-only ones marked harmless
  release.py next                 the next runbook step for the newest release, as the exact
                                  lines Kev runs with `!`, every number filled in

Why: on 2026-11-05 build 542 was cut at 338c75df before #776 merged and nothing said what it
left out; the same day Xcode Cloud never saw the push for release-1.3.0-20261105-63446054 and a
second "-r2" tag on the same commit started run 544. A "-rN" tag on its base tag's commit is
read as that base tag. The runbook itself is README.md; this reads it off git and the API and
reuses release_tag / builds / precheck / submit for every read. Read-only: GETs and a git fetch.

Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.8, Prior: none
The pure half (parse_prs, classify_docs, next_steps, status_lines) is pinned in test_release.py;
the live reads are the neighbours' own, run against build 542 and 544 on 2026-11-05.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import builds
from precheck import SUBMITTABLE_STATES, latest_version
from release_tag import PREFIX, RELEASE_TAGS, git
from submit import QUEUED_STATES, SHIPPING_PLATFORMS, STAMP_DIR, gate_problems

CD = "cd ~/Development/m1k3/macos/tools/asc && "
# A version in one of these takes `submit` (READY_FOR_REVIEW on a VERSION: prepared, not sent).
SEND_STATES = SUBMITTABLE_STATES + ("READY_FOR_REVIEW",)
APPROVED_STATES = ("PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "ACCEPTED")
LIVE_STATES = ("READY_FOR_SALE",)
# Store copy goes live through `deliver`, never inside a binary (#777's promo text).
DOCS_PREFIXES = (".claude/",)
DOCS_PARTS = ("docs",)
STORE_COPY = re.compile(r"(^|/)fastlane/metadata_[^/]+/")
PR_SUFFIX = re.compile(r"\(#(\d+)\)\s*$")
RETAG = re.compile(r"^(?P<base>.+)-r(?P<n>\d+)$")

# --------------------------------------------------------------------------- #
# Pure (unit-pinned)
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Excluded:
    """A first-parent commit on origin/master after the tag: in master, NOT in this build."""

    number: int | None
    subject: str
    docs: bool


@dataclass(frozen=True)
class Version:
    """A platform's newest App Store version: its string, appStoreState and attached build."""

    version: str
    state: str
    build: str | None


@dataclass
class State:
    tag: str = ""
    commit: str = ""
    aliases: tuple[str, ...] = ()
    head: str = ""
    head_tagged: bool = False
    excluded: tuple[Excluded, ...] = ()
    run: int | None = None
    outcome: str | None = None
    builds: dict[str, str] = field(default_factory=dict)
    stamped: bool = False
    versions: dict[str, Version | None] = field(default_factory=dict)
    retag: str = ""


def parse_prs(subjects: list[str]) -> list[tuple[int, str]]:
    """(PR number, subject) for each squash-merge subject; the trailing "(#NNN)" is the PR's."""
    out = []
    for subject in subjects:
        match = PR_SUFFIX.search(subject)
        if match:
            out.append((int(match.group(1)), subject))
    return out


def classify_docs(paths: list[str]) -> bool:
    """True when every path is docs: *.md, a docs/ directory, .claude, or store copy. An empty
    list (a diff that failed to read) is not docs: unknown must WARN, never read as harmless."""
    if not paths:
        return False

    def is_docs(path: str) -> bool:
        parts = path.split("/")
        return (path.endswith(".md") or path.startswith(DOCS_PREFIXES) or "/.claude/" in path
                or any(p in DOCS_PARTS for p in parts[:-1]) or bool(STORE_COPY.search(path)))

    return all(is_docs(p) for p in paths)


def parse_tag_refs(out: str) -> list[tuple[str, str]]:
    """`for-each-ref --format=%(refname:short)%09%(objectname)%09%(*objectname)` → (tag, commit):
    an annotated tag's commit is its peeled id, a lightweight tag's is its own."""
    refs = []
    for line in out.splitlines():
        name, _, rest = line.partition("\t")
        oid, _, peeled = rest.partition("\t")
        if name and oid:
            refs.append((name, peeled.strip() or oid.strip()))
    return refs


def alias_base(tag: str, tags: dict[str, str]) -> str:
    """A "-rN" re-trigger tag on its base tag's commit IS that release; elsewhere it stands alone."""
    match = RETAG.match(tag)
    if match and tags.get(match.group("base")) == tags.get(tag):
        return match.group("base")
    return tag


def retag_name(tag: str, tags: dict[str, str]) -> str:
    """The next free "-rN" for re-triggering Xcode Cloud on the same commit (run 544's route)."""
    base = alias_base(tag, tags)
    n = 2
    while f"{base}-r{n}" in tags:
        n += 1
    return f"{base}-r{n}"


def _version_notes(versions: dict[str, Version | None], build: str) -> tuple[list[str], list[str]]:
    """(cancel lines, notes) for the platforms not yet carrying `build`."""
    cancels, notes = [], []
    for platform in SHIPPING_PLATFORMS:
        v = versions.get(platform)
        if v is None:
            notes.append(f"{platform}: no version: create the next version in App Store Connect first")
        elif v.build == build:
            continue
        elif v.state in QUEUED_STATES:
            cancels.append(CD + f"./submit.py cancel --platform {platform} --confirm --wait")
        elif v.state not in SEND_STATES:
            notes.append(f"{platform} {v.version} is {v.state}: create the new version in App Store Connect first")
    return cancels, notes


def next_steps(state: State) -> list[str]:
    """The next runbook step. Lines starting with CD are for Kev to run with `!`; others are notes."""
    code = [e for e in state.excluded if not e.docs]
    if not state.tag or (not state.head_tagged and code):
        steps = [CD + "./release_tag.py cut --confirm"]
        queued = {p: v for p, v in state.versions.items() if v is not None and v.state in QUEUED_STATES}
        if queued:
            on = ", ".join(f"{p} {v.version} on build {v.build}" for p, v in queued.items())
            steps.append(f"note: {on} is in review: the new build means a cancel later (the queue spot is the price)")
        return steps
    n = str(state.run) if state.run is not None else ""
    if state.run is None:
        steps = [CD + "./builds.py wait"]
        if state.retag:
            steps.append(f"if no run appears ~10 min after the tag, Xcode Cloud missed the push (2026-11-05): "
                         f"{CD}git tag -a {state.retag} {state.commit} -m 're-trigger Xcode Cloud' "
                         f"&& git push origin {state.retag}")
        return steps
    if state.outcome == "running":
        return [CD + "./builds.py wait"]
    if state.outcome == "canceled":
        return [f"run {n} was CANCELED: if it died seconds after creation, Xcode Cloud is out of hours; build it here",
                CD + f"../release/release-local.sh {n}",
                f"then the upload-local.zsh line it prints, then {CD}./testflight.py notes --build {n} --confirm"]
    if state.outcome != "succeeded":
        return [f"run {n} {state.outcome}: read it in Xcode Cloud before anything else"]
    if not builds.ready(state.builds, SHIPPING_PLATFORMS):
        return [CD + "./builds.py wait"]
    if not state.stamped:
        return [f"install build {n} from TestFlight on this Mac, then quit and relaunch M1K3",
                CD + f"./verify_build.py --build {n}"]
    cancels, notes = _version_notes(state.versions, n)
    if any(v is None or v.build != n for v in (state.versions.get(p) for p in SHIPPING_PLATFORMS)):
        return notes + cancels + [CD + f"./submit.py attach --platform ALL --build {n} --confirm && ./precheck.py"]
    shipped = {p: state.versions[p] for p in SHIPPING_PLATFORMS}
    states = [v.state for v in shipped.values() if v is not None]
    if any(s in SEND_STATES for s in states):
        return [CD + "./submit.py submit --platform ALL --confirm"]
    odd = [f"{p} {v.version} is {v.state}: read it in App Store Connect" for p, v in shipped.items()
           if v is not None and v.state not in QUEUED_STATES + APPROVED_STATES + LIVE_STATES]
    if odd:
        return odd
    if any(s in QUEUED_STATES for s in states):
        return ["in review: nothing to do"]
    if any(s in APPROVED_STATES for s in states):
        return ["approved: release it in App Store Connect when you choose (Kev's call)"]
    return ["live: nothing to do"]


def status_lines(state: State) -> list[str]:
    if not state.tag:
        return ["no release tag on origin: cut one with ./release_tag.py cut --confirm"]
    alias = f" (alias: {', '.join(state.aliases)})" if state.aliases else ""
    lines = [f"tag      {state.tag}{alias} → {state.commit[:8]}"]
    if state.run is None:
        lines.append(f"run      no Xcode Cloud run for {state.commit[:8]} in the last 10")
    else:
        lines.append(f"run      Xcode Cloud run {state.run} {state.outcome} · build {state.run}")
        if state.builds:
            lines.append("builds   " + ", ".join(f"{p} {s}" for p, s in state.builds.items()))
    for platform in SHIPPING_PLATFORMS:
        v = state.versions.get(platform)
        lines.append(f"{platform:<8} " + ("no version (or the read failed)" if v is None
                                          else f"{v.version} {v.state} · build {v.build or 'none attached'}"))
    if state.run is not None:
        stamp = STAMP_DIR / f"verified-{state.run}.json"
        lines.append(f"stamp    {stamp}: " + ("verified" if state.stamped else "not verified on this Mac"))
    lines.append("Merged on origin/master after this tag (NOT in this build):")
    if not state.excluded:
        lines.append("  none")
    for e in state.excluded:
        number = f"#{e.number}" if e.number is not None else "(no PR)"
        lines.append(f"  {number:<7} {'docs-only (harmless)' if e.docs else 'CODE':<20} {e.subject}")
    code = [e for e in state.excluded if not e.docs]
    if code:
        names = ", ".join(f"#{e.number}" if e.number is not None else e.subject for e in code)
        lines.append(f"WARN {len(code)} non-docs change(s) on master are not in build {state.run or '?'}: {names}")
    return lines


# --------------------------------------------------------------------------- #
# git + ASC reads (thin)
# --------------------------------------------------------------------------- #


def release_tags() -> list[tuple[str, str]]:
    """(tag, commit), newest first, after fetching origin's release tags and master."""
    if git("fetch", "-q", "origin", "master", RELEASE_TAGS).returncode != 0:
        raise SystemExit("could not fetch origin (master + release tags)")
    out = git("for-each-ref", "--sort=-creatordate", f"refs/tags/{PREFIX}*",
              "--format=%(refname:short)%09%(objectname)%09%(*objectname)")
    return parse_tag_refs(out.stdout)


def excluded_since(commit: str) -> tuple[Excluded, ...]:
    out = git("log", "--first-parent", "--reverse", "--format=%H%x09%s", f"{commit}..origin/master")
    if out.returncode != 0:
        raise SystemExit(f"git log {commit[:8]}..origin/master failed: {out.stderr.strip()}")
    rows = []
    for line in out.stdout.splitlines():
        sha, _, subject = line.partition("\t")
        prs = parse_prs([subject])
        paths = git("diff", "--name-only", f"{sha}^1", sha).stdout.split()
        rows.append(Excluded(prs[0][0] if prs else None, subject, classify_docs(paths)))
    return tuple(rows)


def read_state(tag_arg: str | None) -> State:
    refs = release_tags()
    tags = dict(refs)
    head = git("rev-parse", "origin/master").stdout.strip()
    if tag_arg is None and not refs:
        return State(head=head)
    tag = tag_arg if tag_arg is not None else refs[0][0]
    if tag not in tags:
        raise SystemExit(f"no release tag {tag} on origin")
    tag = alias_base(tag, tags)
    commit = tags[tag]
    aliases = tuple(sorted(t for t in tags if t != tag and alias_base(t, tags) == tag))
    state = State(tag=tag, commit=commit, aliases=aliases, head=head, head_tagged=head in tags.values(),
                  excluded=excluded_since(commit), retag=retag_name(tag, tags))
    run = builds.run_for_commit(builds.recent_runs(builds.product_id()), commit)
    if run is not None:
        state.run = int(run["attributes"]["number"])
        state.outcome = builds.run_outcome(run)
        if state.outcome == "succeeded":
            state.builds = builds.build_states(str(state.run), SHIPPING_PLATFORMS)
        state.stamped = not gate_problems(str(state.run))
    for platform in SHIPPING_PLATFORMS:
        v = latest_version(platform)
        if v is None:
            state.versions[platform] = None
            continue
        a = v["attributes"]
        build = ((v.get("_build") or {}).get("attributes") or {}).get("version")
        state.versions[platform] = Version(a["versionString"], a.get("appStoreState") or "?", build)
    return state


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("status")
    s.add_argument("--tag", default=None, help="default: the newest release tag on origin")
    sub.add_parser("next")
    args = ap.parse_args()
    state = read_state(getattr(args, "tag", None))
    if args.cmd == "status":
        print("\n".join(status_lines(state)))
        return 0
    print(f"{state.tag or 'no release tag'}" + (f" · build {state.run}" if state.run is not None else ""))
    print("\n".join(next_steps(state)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
