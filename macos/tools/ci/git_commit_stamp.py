#!/usr/bin/env python3
"""Print the build-commit stamp for Info.plist's GitCommitSHA.

Called by the `Stamp GitCommitSHA` post-build phase in project.yml (after
ProcessInfoPlistFile, before signing) and by the Xcode Cloud hooks. Resolution order:

  1. $CI_COMMIT (Xcode Cloud has no .git-state guarantee; it names the commit)
  2. `git rev-parse --short HEAD`, plus `-dirty` if `git status --porcelain`
     is non-empty (untracked files count: a local build is not that commit)
  3. `unknown` when git is unavailable or the directory is not a checkout

    git_commit_stamp.py [REPO_DIR]        # prints the stamp, always exits 0

Stdlib only; run with `python3 -I`. A stamp failure must never fail a build.

Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8, Prior: none.
"""
from __future__ import annotations

import os
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path


def _git(repo: Path, *args: str) -> str | None:
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), *args], capture_output=True, text=True, check=True, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout


def stamp(repo: Path, env: Mapping[str, str] | None = None) -> str:
    env = os.environ if env is None else env
    ci = (env.get("CI_COMMIT") or "").strip()
    if ci:
        return ci[:8]
    sha = (_git(repo, "rev-parse", "--short", "HEAD") or "").strip()
    if not sha:
        return "unknown"
    status = _git(repo, "status", "--porcelain")
    return sha + "-dirty" if status is None or status.strip() else sha


if __name__ == "__main__":
    print(stamp(Path(sys.argv[1] if len(sys.argv) > 1 else ".")))
