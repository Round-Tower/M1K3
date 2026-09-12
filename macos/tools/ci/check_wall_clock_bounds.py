#!/usr/bin/env python3
"""Fail on a test that asserts it finished within a short wall-clock bound.

Swift Testing starts every test at once. On the 3-core macos-26 CI runner a
test's measured wall time is mostly the wait for the shared cooperative pool,
not its own work: the 2026-09-12 master run reported 3,318 of 3,699 tests at
7-8 s in a run that took 13.4 s end to end, and a Slowloris test's `< 4 s`
bound measured 6.3 s (issue #296). Five PRs in two days paid a rerun for this.

A bound that separates two outcomes (the server's 0.3 s deadline vs the
client's fallback) must sit far between them: 30 s or more, with the fallback
moved out past it. Better still, assert which side acted. A line that truly
needs a short bound (an opt-in test outside the parallel suite) carries
`// wall-clock-ok: <reason>`.

    python3 check_wall_clock_bounds.py [TESTS_DIR]

Defaults to the repo's macos/Tests. Read-only. The pure helpers are pinned in
test_check_wall_clock_bounds.py.

Signed: Kev + claude-opus-5, 2026-09-12, Confidence 0.85 (the backlog is read
off the run's own xunit timings; the patterns cover every bound in Tests/ today
and are pinned; a novel spelling of a clock bound would slip past). Prior: Unknown
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

FLOOR_SECONDS = 30.0
ALLOW = "wall-clock-ok"

_DURATION = re.compile(r"<=?\s*(?:Duration)?\.(seconds|milliseconds)\(\s*(\d+(?:\.\d+)?)\s*\)")
# A clock read on the left of the comparison: `.now`, `duration(to:`, or an
# identifier containing start / clock / elapsed (`startTime`, `clockStart`).
# A duration held in a variable named anything else slips past — the allow
# marker and review cover that gap.
_CLOCK = re.compile(r"\.now\b|duration\(to:|\b\w*(?:start|clock|elapsed)\w*\b", re.IGNORECASE)
_BARE = re.compile(r"(?<![\w.])(?:elapsed|timeIntervalSince\([^)]*\))\s*<=?\s*(\d+(?:\.\d+)?)(?![\w.(])")


def _code(line: str) -> str:
    """`line` with a trailing `//` comment removed — but not a `//` inside a
    string literal (a URL in an #expect message)."""
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and in_string:
            i += 2
            continue
        if ch == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i]
        i += 1
    return line


def short_bound(line: str) -> float | None:
    """The bound in seconds when `line` asserts a wall-clock bound under the floor."""
    if ALLOW in line:
        return None
    code = _code(line)
    if not code.strip():
        return None
    for match in _DURATION.finditer(code):
        if not _CLOCK.search(code[: match.start()]):
            continue  # a configured duration compared to a literal — no clock read
        unit, value = match.groups()
        seconds = float(value) / (1000 if unit == "milliseconds" else 1)
        if seconds < FLOOR_SECONDS:
            return seconds
    for value in _BARE.findall(code):
        if float(value) < FLOOR_SECONDS:
            return float(value)
    return None


def _statements(text: str):
    """(first line number, joined text) per statement: a line that leaves a
    paren open is joined with the following lines until it closes, so a
    comparison split across lines is judged whole."""
    buffer, start, depth = [], 0, 0
    for number, line in enumerate(text.splitlines(), start=1):
        code = _code(line)
        if not buffer:
            start = number
        buffer.append(line if ALLOW in line else code)
        depth += code.count("(") - code.count(")")
        if depth <= 0 or len(buffer) >= 12:
            yield start, " ".join(part.strip() for part in buffer)
            buffer, depth = [], 0
    if buffer:
        yield start, " ".join(part.strip() for part in buffer)


def scan(files: dict[str, str]) -> list[tuple[str, int, float]]:
    hits = []
    for path, text in sorted(files.items()):
        for number, statement in _statements(text):
            bound = short_bound(statement)
            if bound is not None:
                hits.append((path, number, bound))
    return hits


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "Tests"
    files = {str(p.relative_to(root.parent)): p.read_text(encoding="utf-8") for p in root.rglob("*.swift")}
    hits = scan(files)
    for path, number, bound in hits:
        print(f"{path}:{number}: a {bound:g} s wall-clock bound — under the parallel suite a test's wall time "
              f"is mostly queueing (#296). Bound at >= {FLOOR_SECONDS:g} s with the fallback moved past it, "
              f"assert which side acted, or mark `// {ALLOW}: <reason>`.")
    if hits:
        return 1
    print(f"ok: no wall-clock bound under {FLOOR_SECONDS:g} s in {len(files)} test files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
