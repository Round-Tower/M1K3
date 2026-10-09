#!/usr/bin/env python3
"""Print the build-commit stamp for Info.plist's GitCommitSHA.

Called by the `Stamp GitCommitSHA` post-build phase in project.yml (after
ProcessInfoPlistFile, before signing) and by the Xcode Cloud hooks. Resolution order:

  1. $CI_COMMIT (Xcode Cloud has no .git-state guarantee; it names the commit),
     cut to 8 characters
  2. `git rev-parse --short HEAD` (7 or more characters: git widens it to stay
     unique), plus `-dirty` if `git status --porcelain` is non-empty (untracked
     files count: a local build is not that commit)
  3. `unknown` when git is unavailable or the directory is not a checkout

The CI and local stamps are different lengths, so consumers (run_chateval.py's
scorecard, anyone comparing a build to a commit) must PREFIX-match, never
compare for equality. The final value is validated against STAMP_RE before it
is printed — it is interpolated into a PlistBuddy command by the build phase —
and anything else (a CI_COMMIT with a space or `;`) becomes `unknown`, with a
`warning:` on stderr so the build log shows the loss.

    git_commit_stamp.py [REPO_DIR]        # prints the stamp, always exits 0

Stdlib only; run with `python3 -I`. A stamp failure must never fail a build.

Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8, Prior: Unknown.
Review: Kev + claude-fable-5.1, 2026-10-09 (#522 review fold) — the stamp is validated
against STAMP_RE and `unknown` warns on stderr; docstring says the two lengths.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path

#: A hex prefix (7–40), optionally `-dirty`, or the literal `unknown`: the only
#: shapes the build phase may hand to PlistBuddy.
STAMP_RE = re.compile(r"^[0-9a-f]{7,40}(-dirty)?$|^unknown$")


def _git(repo: Path, *args: str) -> str | None:
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), *args], capture_output=True, text=True, check=True, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout


def _raw_stamp(repo: Path, env: Mapping[str, str]) -> str:
    ci = (env.get("CI_COMMIT") or "").strip()
    if ci:
        return ci[:8]
    sha = (_git(repo, "rev-parse", "--short", "HEAD") or "").strip()
    if not sha:
        return "unknown"
    status = _git(repo, "status", "--porcelain")
    return sha + "-dirty" if status is None or status.strip() else sha


def stamp(repo: Path, env: Mapping[str, str] | None = None) -> str:
    """The validated stamp; `unknown` (and a stderr warning) for anything off-pattern."""
    env = os.environ if env is None else env
    raw = _raw_stamp(repo, env)
    if STAMP_RE.fullmatch(raw) and raw != "unknown":
        return raw
    why = "git or CI_COMMIT unavailable" if raw == "unknown" else f"stamp {raw!r} is not a hex prefix"
    print(f"warning: GitCommitSHA is unknown ({why}); the build cannot be matched to a commit", file=sys.stderr)
    return "unknown"


if __name__ == "__main__":
    print(stamp(Path(sys.argv[1] if len(sys.argv) > 1 else ".")))
