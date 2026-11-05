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
* archive/* tags pointing at the tip

VERDICT is one of LANDED, ARCHIVED (both safe to delete), OPEN PR #N, LIVE, or
LIVE+CONFLICTS (n files). A dirty, locked or unreadable worktree is never safe, and
neither is a branch the verdict does not call landed or archived. The report ends
with the `git worktree remove` / `git branch -D` lines for the safe ones, ready to
paste after `!`. The script never runs them: it only reads.

    branch_audit.py [--repo DIR] [--base origin/master] [--no-gh]

Known blind spot, on the safe side: a squash-merged branch whose lines master later
rewrote reads LIVE+CONFLICTS (the 3-way merge sees two edits), so it is kept, never
offered. Stdlib only; run with `python3 -I`.

Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.8, Prior: none
Written after build 542 and a lost tag push left the branch list unreadable; pinned in test_branch_audit.py.
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


@dataclass
class BranchFacts:
    branch: str
    remote_exists: bool
    prs: list[dict] | None  # None: lookup skipped or failed
    worktree: str | None
    worktree_locked: bool
    worktree_missing: bool
    dirty: int | None  # None: no worktree, or unreadable
    ahead: int
    behind: int
    landed: bool
    conflicts: list[str]
    merge_error: str | None
    archive_tags: list[str]
    size: str | None
    pr_error: str = field(default="")


# --- pure ----------------------------------------------------------------------


def parse_worktrees(porcelain: str) -> dict[str, Worktree]:
    """`git worktree list --porcelain` -> {branch: Worktree}; detached worktrees are dropped."""
    out: dict[str, Worktree] = {}
    for block in porcelain.strip().split("\n\n"):
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
            out[branch] = Worktree(path, locked=locked, prunable=prunable)
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


def verdict(f: BranchFacts) -> str:
    """LANDED > ARCHIVED > OPEN PR #N > LIVE+CONFLICTS (n files) > LIVE."""
    if f.landed:
        return "LANDED"
    if f.archive_tags:
        return "ARCHIVED"
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
    if v not in ("LANDED", "ARCHIVED"):
        return False, f"verdict is {v}"
    if f.worktree and not f.worktree_missing:
        if f.worktree_locked:
            return False, "worktree is locked (in use)"
        if f.dirty is None:
            return False, "worktree status unreadable"
        if f.dirty:
            return False, f"worktree has {f.dirty} dirty file{'' if f.dirty == 1 else 's'}"
    return True, ""


def cleanup_commands(facts: list[BranchFacts]) -> list[str]:
    """The '!'-ready deletions for the safe branches: worktree first, then the branch."""
    cmds: list[str] = []
    prune = False
    deletes: list[str] = []
    for f in facts:
        if not is_safe(f)[0]:
            continue
        if f.worktree and f.worktree_missing:
            prune = True
        elif f.worktree:
            cmds.append(f"git worktree remove {shlex.quote(f.worktree)}")
        deletes.append(f"git branch -D {shlex.quote(f.branch)}")
    return cmds + (["git worktree prune"] if prune else []) + deletes


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


def render(facts: list[BranchFacts], base: str) -> str:
    out: list[str] = [f"Branch audit against {base} ({len(facts)} branches, by content)", ""]
    for f in facts:
        if f.worktree:
            wt = f.worktree
            if f.worktree_missing:
                wt += " (missing on disk: prunable)"
            else:
                dirty = "?" if f.dirty is None else str(f.dirty)
                wt += f"  dirty: {dirty}  size: {f.size or '?'}"
                if f.worktree_locked:
                    wt += "  LOCKED"
        else:
            wt = "none"
        safe, why = is_safe(f)
        v = verdict(f)
        tail = "safe to delete" if safe else (
            f"keep: {why}" if v in ("LANDED", "ARCHIVED") else "keep")
        out += [
            f.branch,
            f"  remote: {'yes' if f.remote_exists else 'no'}   PR: {_pr_line(f)}",
            f"  worktree: {wt}",
            f"  vs {base}: {f.ahead} ahead, {f.behind} behind",
            f"  merge: {_merge_line(f, base)}",
            f"  archive tags: {', '.join(f.archive_tags) or 'none'}",
            f"  VERDICT: {v} ({tail})",
            "",
        ]
    cmds = cleanup_commands(facts)
    out.append("Cleanup ('!'-ready; safe branches only, NOT run):")
    out += cmds or ["  (nothing safe to delete)"]
    return "\n".join(out) + "\n"


# --- I/O -----------------------------------------------------------------------


def _run(cmd: list[str], cwd: Path | None = None, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


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


def _facts_for(repo: Path, base: str, base_tree: str, remote: str | None, branch: str,
               wt: Worktree | None, prs: PRLookup | None) -> BranchFacts:
    remote_exists = bool(remote) and _git(
        repo, "rev-parse", "--verify", "--quiet", f"refs/remotes/{remote}/{branch}").returncode == 0

    pr_rows: list[dict] | None = None
    pr_error = ""
    if prs is not None:
        try:
            pr_rows = prs(branch)
        except Exception as e:  # noqa: BLE001 — a failed lookup is reported, never fatal
            pr_error = str(e) or type(e).__name__

    counts = _git(repo, "rev-list", "--left-right", "--count", f"{base}...refs/heads/{branch}").stdout.split()
    behind, ahead = (int(counts[0]), int(counts[1])) if len(counts) == 2 else (0, 0)

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

    worktree = wt.path if wt else None
    missing = bool(wt) and (wt.prunable or not Path(wt.path).is_dir())
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
        archive_tags=sorted(tags), size=size, pr_error=pr_error,
    )


def gather(repo: Path, base: str, prs: PRLookup | None) -> list[BranchFacts]:
    base_tree = _git(repo, "rev-parse", f"{base}^{{tree}}")
    if base_tree.returncode != 0:
        raise SystemExit(f"branch_audit: cannot resolve {base}: {base_tree.stderr.strip()}")
    remote = _remote_of(repo, base)
    worktrees = parse_worktrees(_git(repo, "worktree", "list", "--porcelain").stdout)
    branches = _git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads").stdout.split()
    return [
        _facts_for(repo, base, base_tree.stdout.strip(), remote, b, worktrees.get(b), prs)
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
