#!/usr/bin/env python3
"""build_eval_app.py — build the M1K3.app an eval arm runs, from a commit, and prove it.

  python3 macos/tools/eval/build_eval_app.py <worktree> <derived-data> [--dry-run]
  APP=$(python3 macos/tools/eval/build_eval_app.py ~/Development/m1k3-x ~/eval-dd/x)

Eval builds come from a COMMIT, so the commit sha is the build's identity. A worktree with
anything in `git status --porcelain` (untracked files included) is refused before anything
runs: on 2026-10-18 one "03aefb58-dirty" stamp covered two different trees, because the
untracked ThinkBudget files came and went, and `git diff HEAD` never sees untracked files.
Commit first (a WIP branch with TDD_SKIP="eval arm build" is fine); the sha then names it.

Then `xcodegen generate` and the one xcodebuild line the 10-18 arms were built with (Debug,
arm64, the two worktree -skip validations, resolved package versions only), both logged to
<derived-data>/eval-build.log. The exit code is not the verdict: `verify_build` reads the log
(`BUILD SUCCEEDED`, zero " error: " lines) and the app's stamped GitCommitSHA, which must be a
clean hex prefix of HEAD — "-dirty" fails. On success the .app path is the ONLY stdout line;
everything else goes to stderr. Exit 2 not a checkout, 3 dirty, 4 the build did not verify.

Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.8, Prior: none (new file; replaces the
scratchpad build.zsh and build5–10.zsh). verify_build, the refusal and the glue are pinned in
test_build_eval_app.py against a fake build; the real xcodebuild line is build10.zsh's,
unchanged, and has not yet been run through this file.
Review: Kev + claude-opus-5-5, 2026-10-18 — the stamp is read by run_chateval's `app_commit` (one reader, not a
copy); `_run`'s log-only output, exit 2, the xcodegen failure and a non-zero xcodebuild are now pinned too.
"""

from __future__ import annotations

import argparse
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import TextIO

from run_chateval import app_commit  # the one reader of the stamp

_HEX_STAMP = re.compile(r"[0-9a-f]{7,40}")  # what git_commit_stamp.py writes for a clean tree


def verify_build(log_text: str, stamped_sha: str | None, head_sha: str) -> list[str]:
    """Why this build is not HEAD's clean build; empty when it is. The stamp must be a hex
    prefix of HEAD (git widens `--short`; Xcode Cloud stamps 8) with no suffix: never the
    `^sha` match that passed "03aefb58-dirty" on 2026-10-18."""
    problems = []
    if "BUILD SUCCEEDED" not in log_text:
        problems.append("no BUILD SUCCEEDED in the log")
    errors = [line.strip() for line in log_text.splitlines() if " error: " in line]
    if errors:
        problems.append(f"{len(errors)} error line{'s' if len(errors) != 1 else ''} in the log, first: {errors[0][:200]}")
    if not stamped_sha:
        problems.append("no GitCommitSHA in the app's Info.plist (built outside the Stamp phase?)")
    elif not (_HEX_STAMP.fullmatch(stamped_sha) and head_sha.startswith(stamped_sha)):
        problems.append(f"the app is stamped {stamped_sha!r} but HEAD is {head_sha[:12]}: not this commit's clean build")
    return problems


def commands(derived_data: Path) -> list[list[str]]:
    """xcodegen, then build10.zsh's xcodebuild line (both run in the worktree's macos/)."""
    return [
        ["xcodegen", "generate"],
        ["xcodebuild", "-scheme", "M1K3", "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64",
         "-derivedDataPath", str(derived_data), "-skipPackagePluginValidation", "-skipMacroValidation",
         "-onlyUsePackageVersionsFromResolvedFile", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "build"],
    ]


def app_path(derived_data: Path) -> Path:
    return derived_data / "Build/Products/Debug/M1K3.app"


# ── side effects (thin; the build itself is the `_run` seam the tests replace) ──

def _git(worktree: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(worktree), *args], capture_output=True, text=True, check=True).stdout


def dirty_reason(worktree: Path) -> str | None:
    """None for a clean checkout; otherwise why it may not build an eval app."""
    try:
        status = _git(worktree, "status", "--porcelain", "--untracked-files=normal")
    except (OSError, subprocess.CalledProcessError) as err:
        return f"{worktree} is not a git checkout ({err})"
    changed = status.splitlines()
    if not changed:
        return None
    shown = "\n  ".join(changed[:10]) + ("\n  …" if len(changed) > 10 else "")
    return (f"{worktree} has {len(changed)} uncommitted change(s), untracked files included; an eval build "
            f"comes from a commit (TDD_SKIP=\"eval arm build\" on a WIP branch):\n  {shown}")


def _run(cmd: list[str], cwd: Path, log: TextIO) -> int:
    log.flush()
    return subprocess.run(cmd, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, check=False).returncode


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("worktree", type=Path, help="the checkout to build (its root, or its macos/)")
    ap.add_argument("derived_data", type=Path, help="-derivedDataPath; the log lands here as eval-build.log")
    ap.add_argument("--dry-run", action="store_true", help="refuse or print the commands; build nothing")
    args = ap.parse_args(argv)
    worktree, dd = args.worktree.expanduser().resolve(), args.derived_data.expanduser().resolve()
    macos = worktree / "macos" if (worktree / "macos/project.yml").exists() else worktree

    reason = dirty_reason(worktree)
    if reason:
        print(f"✗ {reason}", file=sys.stderr)
        return 2 if "not a git checkout" in reason else 3
    cmds = commands(dd)
    if args.dry_run:
        for cmd in cmds:
            print(f"cd {shlex.quote(str(macos))} && {shlex.join(cmd)}")
        return 0

    head = _git(worktree, "rev-parse", "HEAD").strip()
    log_path = dd / "eval-build.log"
    dd.mkdir(parents=True, exist_ok=True)
    print(f"▸ building {head[:12]} → {log_path}", file=sys.stderr)
    with open(log_path, "w") as log:
        if _run(cmds[0], macos, log) != 0:
            print(f"✗ xcodegen failed — read {log_path}", file=sys.stderr)
            return 4
        reason = dirty_reason(worktree)
        if reason:
            print(f"✗ xcodegen left the tree dirty, so the stamp would be too — {reason}", file=sys.stderr)
            return 4
        code = _run(cmds[1], macos, log)
    problems = verify_build(log_path.read_text(errors="replace"), app_commit(app_path(dd)), head)
    if code != 0:
        problems.append(f"xcodebuild exited {code}")
    if problems:
        for problem in problems:
            print(f"✗ {problem}", file=sys.stderr)
        print(f"  log: {log_path}", file=sys.stderr)
        return 4
    print(app_path(dd))
    return 0


if __name__ == "__main__":
    sys.exit(main())
