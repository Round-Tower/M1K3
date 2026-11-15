"""Xcode Cloud's hooks run under `set -euo pipefail`: a pipe into a reader that quits early
(`head`, `grep -q`, `grep -m`) can SIGPIPE the writer, and pipefail + -e kills the hook.

Run 552 (release-1.5.0, 2026-11-15): the iOS archive's ci_post_clone.log stops after
"Xcode 27.2" with exit 141. `xcodebuild -version | head -1` lost the race writing its
second line; the Mac archive of the same commit won it. Read the first line with
`sed -n 1p`, which reads to the end.

Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.9 (the log proves the line; the
race is timing). Prior: none (new file).
"""
from __future__ import annotations

import re
from pathlib import Path

CI_SCRIPTS = Path(__file__).resolve().parents[2] / "ci_scripts"
EARLY_EXIT_READER = re.compile(r"\|\s*(head\b|grep\s+(-\w*[qm]\w*\b))")


def early_exit_pipes(text: str) -> list[str]:
    """Lines that pipe into a reader that can quit before the writer finishes."""
    found = []
    for line in text.splitlines():
        code = line.split("#", 1)[0]
        if EARLY_EXIT_READER.search(code):
            found.append(line.strip())
    return found


def test_the_pattern_catches_head_and_quiet_greps() -> None:
    assert early_exit_pipes("xcodebuild -version | head -1") == ["xcodebuild -version | head -1"]
    assert early_exit_pipes("ls | grep -q foo")
    assert early_exit_pipes("ls | grep -m1 foo")
    assert early_exit_pipes("xcodebuild -version | sed -n 1p") == []
    assert early_exit_pipes("ls | grep foo") == []
    assert early_exit_pipes("echo ok  # was: x | head -1") == []


def test_no_pipefail_hook_pipes_into_an_early_exit_reader() -> None:
    offenders = {}
    for script in sorted(CI_SCRIPTS.glob("*.sh")):
        text = script.read_text(encoding="utf-8")
        if "pipefail" in text and (bad := early_exit_pipes(text)):
            offenders[script.name] = bad
    assert offenders == {}, f"pipe into sed -n 1p instead (run 552): {offenders}"
