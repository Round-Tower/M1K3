#!/usr/bin/env python3
"""Audit local branches and worktrees by CONTENT: which are safe to delete, and why.

Squash merges defeat the usual checks: `git log master..branch` still lists a
squash-merged branch's commits, and patch-id misses a squash that folded several
commits (or a review fold) into one. So this asks git a content question instead:

    git merge-tree --write-tree <base> <branch>

If merging the branch into the base yields the base's own tree, merging it changes
nothing, so everything on it is already on the base: LANDED. Exit 1 means the merge
conflicts, and the conflicted files are listed. For each local branch except master:

* the remote branch (on the base's remote), and its PR (`gh pr list --head`, read-only)
* the worktree, its dirty-file count, lock and size (`du -sh`)
* ahead / behind the base
* archive/* tags pointing at the tip, and whether the remote has them at that commit

VERDICT is one of LANDED, ARCHIVED (both safe to delete), LANDED (empty: 0 ahead),
ARCHIVED (local tag only), OPEN PR #N, LIVE, or LIVE+CONFLICTS (n files). Kept on
doubt: a dirty, locked, unreadable or unreachable worktree (a parent directory gone
too may be an unplugged drive), the main worktree's branch, a branch with an open PR,
an empty placeholder, an archive tag the remote lacks. The report ends with the
per-path `git worktree remove` / `git branch -D` lines for the safe ones, ready to
paste after `!` (never `git worktree prune`: it is repo-wide). The script never runs
them. It deletes and pushes nothing; `merge-tree --write-tree` does write unreferenced
tree and blob objects, which gc collects.

    branch_audit.py [--repo DIR] [--base origin/master] [--no-gh]

Known blind spot, on the safe side: a squash-merged branch whose lines master later
rewrote reads LIVE+CONFLICTS (the 3-way merge sees two edits), so it is kept, never
offered. Stdlib only; run with `python3 -I`.

Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.8, Prior: none
Written after build 542 and a lost tag push left the branch list unreadable; pinned in test_branch_audit.py.
Review: Kev + claude-opus-5.5, 2026-11-05 — folded the review: locked before missing, per-path remove not
the global prune, unreachable paths, main worktree / empty / open-PR / local-only archive kept, timeouts. Confidence 0.85.
"""
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

#: A PR lookup: branch name -> gh's JSON rows. Raises on failure.
PRLookup = Callable[[str], list[dict]]

PROTECTED = frozenset({"master", "main"})


@dataclass(frozen=True)
class Worktree:
    path: str
    locked: bool
    prunable: bool
    main: bool = False  # the first porcelain block: the repository's own checkout


@dataclass
class BranchFacts:
    branch: str
    remote_exists: bool
    prs: list[dict] | None  # None: lookup skipped or failed
    worktree: str | None
    worktree_locked: bool
    worktree_missing: bool  # gone from disk, its parent still there: deleted
    dirty: int | None  # None: no worktree, or unreadable
    ahead: int | None  # None: rev-list failed
    behind: int | None
    landed: bool
    conflicts: list[str]
    merge_error: str | None
    archive_tags: list[str]
    size: str | None
    pr_error: str = field(default="")
    archive_remote: list[str] | None = None  # archive tags the remote has at the tip; None: unchecked
    worktree_main: bool = False
    worktree_unreachable: bool = False  # gone AND its parent gone: maybe an unmounted volume


# --- pure ----------------------------------------------------------------------


def parse_worktrees(porcelain: str) -> dict[str, Worktree]:
    """`git worktree list --porcelain` -> {branch: Worktree}; detached worktrees are dropped."""
    out: dict[str, Worktree] = {}
    for i, block in enumerate(porcelain.strip().split("\n\n")):
        path = branch = None
        locked = prunable = False
        for line in block.splitlines():
            key, _, value = line.partition(" ")
            if key == "worktree":
                path = value
            elif key == "branch":
                branch = value.removeprefix("refs/heads/")
            elif key == "locked":
                locked = True
            elif key == "prunable":
                prunable = True
        if path and branch:
            out[branch] = Worktree(path, locked=locked, prunable=prunable, main=i == 0)
    return out


def parse_merge_tree(stdout: str, code: int) -> tuple[str, list[str]]:
    """`merge-tree --write-tree --name-only --no-messages` -> (tree, conflicted files)."""
    lines = stdout.splitlines()
    tree = lines[0].strip() if lines else ""
    files: list[str] = []
    if code == 1:
        for line in lines[1:]:
            if not line.strip():
                break
            if line not in files:
                files.append(line)
    return tree, files


def _open_pr(f: BranchFacts) -> dict | None:
    return next((p for p in f.prs or [] if p.get("state") == "OPEN"), None)


def parse_ls_remote_tags(stdout: str) -> dict[str, str]:
    """`git ls-remote --tags` -> {tag name: the commit it points at} (annotated tags peeled)."""
    out: dict[str, str] = {}
    for line in stdout.splitlines():
        sha, _, ref = line.partition("\t")
        name = ref.removeprefix("refs/tags/")
        if name.endswith("^{}"):
            out[name[:-3]] = sha  # the peeled line wins over the tag object's
        else:
            out.setdefault(name, sha)
    return out


SAFE_VERDICTS = ("LANDED", "ARCHIVED")


def verdict(f: BranchFacts) -> str:
    """LANDED > ARCHIVED > OPEN PR #N > LIVE+CONFLICTS (n files) > LIVE.

    A landed branch with nothing of its own reads LANDED (empty: 0 ahead), and an archive
    tag the remote lacks reads ARCHIVED (local tag only); neither is offered.
    """
    if f.landed:
        return "LANDED (empty: 0 ahead)" if f.ahead == 0 else "LANDED"
    if f.archive_tags:
        return "ARCHIVED" if f.archive_remote else "ARCHIVED (local tag only)"
    pr = _open_pr(f)
    if pr:
        return f"OPEN PR #{pr['number']}"
    if f.conflicts:
        n = len(f.conflicts)
        return f"LIVE+CONFLICTS ({n} file{'' if n == 1 else 's'})"
    return "LIVE"


def is_safe(f: BranchFacts) -> tuple[bool, str]:
    """(safe to delete, why not). Only LANDED or ARCHIVED with a clean, unlocked worktree."""
    v = verdict(f)
    if v not in SAFE_VERDICTS:
        return False, f"verdict is {v}"
    pr = _open_pr(f)
    if pr:
        return False, f"PR #{pr['number']} is still open"
    if f.ahead is None or f.behind is None:
        return False, "ahead/behind unreadable"
    if f.worktree_main:
        return False, "checked out in the main worktree"
    if f.worktree:
        if f.worktree_locked:  # before missing: git keeps a locked entry whose directory is gone
            return False, "worktree is locked (in use)"
        if f.worktree_unreachable:
            return False, "worktree path unreachable (volume not mounted?)"
        if f.worktree_missing:
            return True, ""
        if f.dirty is None:
            return False, "worktree status unreadable"
        if f.dirty:
            return False, f"worktree has {f.dirty} dirty file{'' if f.dirty == 1 else 's'}"
    return True, ""


def cleanup_commands(facts: list[BranchFacts]) -> list[str]:
    """The '!'-ready deletions for the safe branches: worktrees first, then the branches.

    A worktree whose directory is gone is removed by its path too: `git worktree remove`
    drops just that entry, where `git worktree prune` would drop every stale one.
    """
    removes: list[str] = []
    deletes: list[str] = []
    for f in facts:
        if not is_safe(f)[0]:
            continue
        if f.worktree:
            removes.append(f"git worktree remove {shlex.quote(f.worktree)}")
        deletes.append(f"git branch -D {shlex.quote(f.branch)}")
    return removes + deletes


def _pr_line(f: BranchFacts) -> str:
    if f.prs is None:
        return f"lookup failed ({f.pr_error})" if f.pr_error else "skipped (--no-gh)"
    if not f.prs:
        return "none"
    return ", ".join(f"#{p['number']} {p['state']}" for p in f.prs)


def _merge_line(f: BranchFacts, base: str) -> str:
    if f.merge_error:
        return f"merge-tree failed: {f.merge_error}"
    if f.landed:
        return f"clean, changes nothing on {base} (content landed)"
    if f.conflicts:
        return f"CONFLICTS in {len(f.conflicts)}: " + ", ".join(f.conflicts)
    return f"clean, would change {base}"


def _tag_label(tag: str, on_remote: list[str] | None) -> str:
    if on_remote is None:
        return f"{tag} (remote unchecked)"
    return tag if tag in on_remote else f"{tag} (local only)"


def render(facts: list[BranchFacts], base: str) -> str:
    out: list[str] = [f"Branch audit against {base} ({len(facts)} branches, by content)", ""]
    for f in facts:
        if f.worktree:
            wt = f.worktree
            if f.worktree_unreachable:
                wt += " (unreachable: its parent is gone too, volume not mounted?)"
            elif f.worktree_missing:
                wt += " (missing on disk)"
            else:
                dirty = "?" if f.dirty is None else str(f.dirty)
                wt += f"  dirty: {dirty}  size: {f.size or '?'}"
            if f.worktree_locked:
                wt += "  LOCKED"
        else:
            wt = "none"
        safe, why = is_safe(f)
        v = verdict(f)
        tail = "safe to delete" if safe else (f"keep: {why}" if v in SAFE_VERDICTS else "keep")
        known = f.ahead is not None and f.behind is not None
        counts = f"{f.ahead} ahead, {f.behind} behind" if known else "? ahead, ? behind"
        tags = ", ".join(_tag_label(t, f.archive_remote) for t in f.archive_tags)
        out += [
            f.branch,
            f"  remote: {'yes' if f.remote_exists else 'no'}   PR: {_pr_line(f)}",
            f"  worktree: {wt}",
            f"  vs {base}: {counts}",
            f"  merge: {_merge_line(f, base)}",
            f"  archive tags: {tags or 'none'}",
            f"  VERDICT: {v} ({tail})",
            "",
        ]
    cmds = cleanup_commands(facts)
    out.append("Cleanup ('!'-ready; safe branches only, NOT run):")
    out += cmds or ["  (nothing safe to delete)"]
    return "\n".join(out) + "\n"


# --- I/O -----------------------------------------------------------------------


def _run(cmd: list[str], cwd: Path | None = None, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    """A timeout is a failed result (exit 124), so one huge worktree can't crash the audit."""
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", f"timed out after {timeout}s")


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return _run(["git", "-C", str(repo), *args])


def gh_lookup(repo: Path) -> PRLookup:
    def lookup(branch: str) -> list[dict]:
        p = _run(["gh", "pr", "list", "--head", branch, "--state", "all",
                  "--json", "number,state,mergedAt,title"], cwd=repo, timeout=60)
        if p.returncode != 0:
            raise RuntimeError(p.stderr.strip().splitlines()[-1] if p.stderr.strip() else f"exit {p.returncode}")
        return json.loads(p.stdout or "[]")
    return lookup


def _remote_of(repo: Path, base: str) -> str | None:
    head, sep, _ = base.partition("/")
    remotes = _git(repo, "remote").stdout.split()
    return head if sep and head in remotes else None


def _remote_tags(repo: Path, remote: str | None) -> dict[str, str] | None:
    """The remote's archive/* tags, read live (None: no remote, or it can't be reached)."""
    if not remote:
        return None
    p = _git(repo, "ls-remote", "--tags", remote, "refs/tags/archive/*")
    return parse_ls_remote_tags(p.stdout) if p.returncode == 0 else None


def _facts_for(repo: Path, base: str, base_tree: str, remote: str | None, branch: str,
               wt: Worktree | None, prs: PRLookup | None,
               remote_tags: dict[str, str] | None = None) -> BranchFacts:
    remote_exists = bool(remote) and _git(
        repo, "rev-parse", "--verify", "--quiet", f"refs/remotes/{remote}/{branch}").returncode == 0

    pr_rows: list[dict] | None = None
    pr_error = ""
    if prs is not None:
        try:
            pr_rows = prs(branch)
        except Exception as e:  # noqa: BLE001 — a failed lookup is reported, never fatal
            pr_error = str(e) or type(e).__name__

    rl = _git(repo, "rev-list", "--left-right", "--count", f"{base}...refs/heads/{branch}")
    counts = rl.stdout.split()
    behind: int | None = None
    ahead: int | None = None
    if rl.returncode == 0 and len(counts) == 2:
        behind, ahead = int(counts[0]), int(counts[1])

    mt = _git(repo, "merge-tree", "--write-tree", "--name-only", "--no-messages", base, f"refs/heads/{branch}")
    merge_error = None
    tree, conflicts = "", []
    if mt.returncode in (0, 1):
        tree, conflicts = parse_merge_tree(mt.stdout, mt.returncode)
    else:
        merge_error = (mt.stderr.strip().splitlines() or [f"exit {mt.returncode}"])[-1]
    landed = mt.returncode == 0 and tree == base_tree

    tip = _git(repo, "rev-parse", f"refs/heads/{branch}").stdout.strip()
    tags = _git(repo, "tag", "--points-at", tip, "--list", "archive/*").stdout.split()
    archive_remote = None if remote_tags is None else sorted(t for t in tags if remote_tags.get(t) == tip)

    worktree = wt.path if wt else None
    missing = bool(wt) and (wt.prunable or not Path(wt.path).is_dir())
    # git says "prunable" for a deleted directory and an unplugged drive alike; only a
    # parent that is still there shows the directory itself was deleted.
    unreachable = missing and not Path(wt.path).parent.is_dir()
    dirty: int | None = None
    size: str | None = None
    if wt and not missing:
        st = _git(Path(wt.path), "status", "--porcelain")
        dirty = len([l for l in st.stdout.splitlines() if l.strip()]) if st.returncode == 0 else None
        du = _run(["du", "-sh", wt.path], timeout=300)
        size = du.stdout.split()[0] if du.stdout.split() else None

    return BranchFacts(
        branch=branch, remote_exists=remote_exists, prs=pr_rows, worktree=worktree,
        worktree_locked=bool(wt and wt.locked), worktree_missing=missing, dirty=dirty,
        ahead=ahead, behind=behind, landed=landed, conflicts=conflicts, merge_error=merge_error,
        archive_tags=sorted(tags), size=size, pr_error=pr_error, archive_remote=archive_remote,
        worktree_main=bool(wt and wt.main), worktree_unreachable=unreachable,
    )


def gather(repo: Path, base: str, prs: PRLookup | None) -> list[BranchFacts]:
    base_tree = _git(repo, "rev-parse", f"{base}^{{tree}}")
    if base_tree.returncode != 0:
        raise SystemExit(f"branch_audit: cannot resolve {base}: {base_tree.stderr.strip()}")
    remote = _remote_of(repo, base)
    worktrees = parse_worktrees(_git(repo, "worktree", "list", "--porcelain").stdout)
    branches = _git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads").stdout.split()
    remote_tags = _remote_tags(repo, remote)
    return [
        _facts_for(repo, base, base_tree.stdout.strip(), remote, b, worktrees.get(b), prs, remote_tags)
        for b in branches if b not in PROTECTED
    ]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--repo", type=Path, help="repository (default: the current git toplevel)")
    ap.add_argument("--base", default="origin/master", help="what 'landed' means (default origin/master)")
    ap.add_argument("--no-gh", action="store_true", help="skip the gh PR lookups")
    args = ap.parse_args(argv)
    repo = args.repo
    if repo is None:
        top = _run(["git", "rev-parse", "--show-toplevel"])
        if top.returncode != 0:
            print("branch_audit: not inside a git repository", file=sys.stderr)
            return 2
        repo = Path(top.stdout.strip())
    facts = gather(repo, args.base, None if args.no_gh else gh_lookup(repo))
    sys.stdout.write(render(facts, args.base))
    return 0


if __name__ == "__main__":
    sys.exit(main())
