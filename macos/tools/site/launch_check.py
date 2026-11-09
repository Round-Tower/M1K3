#!/usr/bin/env python3
"""The facts the launch posts rest on, re-checked, with drift shown. Run it the morning you post.

  launch_check.py            check everything, print a table, exit 1 on any drift
  launch_check.py --json     the same as JSON (for the board)

What it checks, and against what the posts say (as of 2026-11-09):

  store      iTunes lookup: version 1.3 live; rating count (watch it climb). One store record serves
             Mac and iOS, and the lookup returns the same row for both: it cannot tell them apart
  issues     #179, #111, #121 still OPEN (the "rough edges" cited in every post)
  tests      @Test count in macos/Tests ≈ 6,177 ("about 6,200" in the HN comment)
  targets    non-test SwiftPM targets in macos/Package.swift = 33
  mcp        tool registrations in M1K3MCPKit = 18
  event      the Flight Club in-app event is still PUBLISHED (needs the ASC key; without it the row
             reads `?` UNVERIFIED, which does not fail the run and is not a pass)

A number drifting is not a failure of the post; it is a line to update before you paste.
EXPECTED below is the one place the posts' numbers live: a new launch edits it, nothing else.

Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.8 (written in a jam the evening before
launch week, promoted from scratch/ with its tests; the counts are regex reads of the tree, good to
the tolerance they are compared with, not a parse).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]   # macos/tools/site/ → the repo root
APP_ID = "6780230835"
GH_REPO = "Round-Tower/M1K3"
EXPECTED = {
    "store.version": "1.3",
    "issues.open": ["179", "111", "121"],
    "tests.count": 6177,
    "targets.count": 33,
    "mcp.tools": 18,
}
TEST_TOLERANCE = 60   # "about 6,200" survives this much movement


@dataclass
class Check:
    name: str
    expected: str
    actual: str
    ok: bool
    note: str = ""
    verified: bool = True   # False: the read failed, so `ok` says nothing either way


def store_lookup(fetch=None) -> dict:
    url = f"https://itunes.apple.com/lookup?id={APP_ID}&country=us"
    if fetch is None:
        with urllib.request.urlopen(url, timeout=20) as r:
            return json.loads(r.read().decode())
    return fetch(url)


def check_store(lookup: dict) -> list[Check]:
    r = (lookup.get("results") or [{}])[0]
    version = str(r.get("version", "?"))
    rating = r.get("averageUserRating")
    count = r.get("userRatingCount", 0)
    return [
        Check("store version", EXPECTED["store.version"], version, version == EXPECTED["store.version"]),
        Check("store ratings (US)", "any", f"{count} × {rating}", True, "not a claim in the posts; the measure"),
    ]


def issue_states(numbers: list[str]) -> dict[str, str]:
    out = {}
    for n in numbers:
        try:
            res = subprocess.run(["gh", "issue", "view", n, "--repo", GH_REPO, "--json", "state", "--jq", ".state"],
                                 capture_output=True, text=True, cwd=REPO, check=False, timeout=30)
            out[n] = res.stdout.strip() or f"error: {res.stderr.strip()[:60]}"
        except (OSError, subprocess.TimeoutExpired) as e:   # no gh, or it hung: a failed row, not a traceback
            out[n] = f"error: {e.__class__.__name__}"
    return out


def check_issues(states: dict[str, str]) -> list[Check]:
    return [Check(f"issue #{n}", "OPEN", s, s == "OPEN", "cited as a rough edge") for n, s in states.items()]


def count_tests(tests_dir: Path) -> int:
    n = 0
    for f in tests_dir.rglob("*.swift"):
        n += len(re.findall(r"^\s*@Test\b", f.read_text(errors="ignore"), re.MULTILINE))
    return n


def count_targets(package_swift: Path) -> int:
    s = package_swift.read_text()
    # A declaration opens its own line; `.target(name: "X")` inside a dependency list does not.
    return len(re.findall(r"^\s*\.(?:target|executableTarget)\(", s, re.MULTILINE))


def count_mcp_tools(kit_dir: Path) -> int:
    n = 0
    for f in kit_dir.glob("*.swift"):
        # `Tool(` then its name: a prompt's or a resource's `name:` is not a tool.
        n += len(re.findall(r'\bTool\(\s*name: "', f.read_text(errors="ignore")))
    return n


def check_counts(tests: int, targets: int, mcp: int) -> list[Check]:
    return [
        Check("@Test count", f"≈{EXPECTED['tests.count']}", str(tests),
              abs(tests - EXPECTED["tests.count"]) <= TEST_TOLERANCE, '"about 6,200" in the HN comment'),
        Check("SwiftPM targets", str(EXPECTED["targets.count"]), str(targets), targets == EXPECTED["targets.count"]),
        Check("MCP tools", str(EXPECTED["mcp.tools"]), str(mcp), mcp == EXPECTED["mcp.tools"], "the README says 18"),
    ]


def event_check(returncode: int, stdout: str) -> Check:
    """The Flight Club row from `events.py list` output. A failed read is neither drift nor a pass:
    without the ASC key the script exits non-zero, and that says nothing about the event."""
    if returncode != 0:
        return Check("Flight Club event", "PUBLISHED", f"exit {returncode}", True,
                     "UNVERIFIED: needs the ASC key", verified=False)
    line = next((row for row in stdout.splitlines() if "flight-club" in row), "")
    fields = line.split()
    state = fields[1] if len(fields) > 1 else "not found"
    return Check("Flight Club event", "PUBLISHED", state, state == "PUBLISHED", "runs to 2026-12-01")


def event_state() -> Check:
    script = REPO / "macos/tools/asc/events.py"
    try:
        res = subprocess.run([str(script), "list"], capture_output=True, text=True, cwd=REPO, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:  # no uv, or the API hung: say so, don't fail the table
        return Check("Flight Club event", "PUBLISHED", e.__class__.__name__, True,
                     "UNVERIFIED: the event read did not run", verified=False)
    return event_check(res.returncode, res.stdout)


def render(checks: list[Check]) -> str:
    w = max(len(c.name) for c in checks)
    lines = []
    for c in checks:
        mark = "?" if not c.verified else "✓" if c.ok else "✗"
        lines.append(f"{mark} {c.name:<{w}}  expected {c.expected:<10} actual {c.actual:<14} {c.note}")
    return "\n".join(lines)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--json", action="store_true")
    p.add_argument("--no-event", action="store_true", help="skip the ASC event read")
    a = p.parse_args(argv)
    checks: list[Check] = []
    checks += check_store(store_lookup())
    checks += check_issues(issue_states(EXPECTED["issues.open"]))
    checks += check_counts(count_tests(REPO / "macos/Tests"),
                           count_targets(REPO / "macos/Package.swift"),
                           count_mcp_tools(REPO / "macos/Sources/M1K3MCPKit"))
    if not a.no_event:
        checks.append(event_state())
    if a.json:
        print(json.dumps([asdict(c) for c in checks], indent=1))
    else:
        print(render(checks))
    unverified = [c for c in checks if not c.verified]
    if unverified:
        print(f"\n{len(unverified)} line(s) UNVERIFIED: not read, so not checked.", file=sys.stderr)
    drift = [c for c in checks if not c.ok]
    if drift:
        print(f"\n{len(drift)} line(s) drifted: update the post before you paste.", file=sys.stderr)
    return 1 if drift else 0


if __name__ == "__main__":
    sys.exit(main())
