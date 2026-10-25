#!/usr/bin/env python3
"""Fail when a line the branch ADDS names a path, log marker or argv flag the tree doesn't have.

The bots' most common nit on m1k3 PRs was a comment or doc claiming something the
reader couldn't find. "The header says the stream logs `turn first token:`, but I see
no such code" (#684), "the docstring says marketing/rank_check.py is replaced, but there's
no marketing/ tree" (#673). Half the time the claim was true and the reviewer couldn't see it: the
#684 marker is in TurnPhaseTimeline.swift, landed in #683, outside the diff a review
reads. Either way the question can be settled mechanically, so this settles it.

Only lines the branch adds are read, so old docs never fail a PR. A backticked span on
an added line is a claim when it is one of three shapes, and it must resolve:

* a path with a source or doc extension (`macos/tools/ci/pr_watch.py`,
  `TurnPhaseTimeline.swift:111`) or a trailing-slash directory (`macos/docs/`) — a tracked
  file must match it exactly, or end with it on a `/` boundary, so `tools/ci/pr_watch.py`
  from macos/ and bare basenames work. Tests are skipped: their strings are fixtures;
* a log marker: lowercase, at least two words, ending in a colon (`turn first token:`)
  — it must sit inside a string literal on a non-comment line of a code file;
* an in-app argv flag: single-dash camelCase (`-postToolAnswer use`) — its bare name
  must be an exact string literal (`"postToolAnswer"`) on a non-comment code line.

Everything else in backticks (shell commands, `--long` flags git and gh own, globs,
URLs, `~` and `$` paths, runtime files like `ranks.jsonl`) is not a claim. Eval
artifacts under docs/evals/ record what was true then, and are skipped. A line that
names something on purpose absent ("replaced `old.py`") carries `claims: skip`.

    python3 tools/ci/check_claims.py                       # local: origin/master...HEAD
    python3 tools/ci/check_claims.py --range HEAD^1..HEAD  # CI: the PR's merge commit

Signed: Kev + claude-opus-5-5, 2026-10-25, Confidence 0.7 (pinned in test_check_claims.py).
Prior: none (new file).
Context: Gemini's "truth gap" steer, measured against the last 25 merged PRs' bot nits
(219 lines): stale-claim nits recur and are mechanical, number and copy nits are not.
Open: the precision of the three shapes is measured on history only (see the PR); a
week of real PRs says whether `claims: skip` stays rare.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections.abc import Callable, Iterable
from dataclasses import dataclass

# Files whose added lines are read: code, docs and workflow text a person reads as fact.
CHECKED_EXT = {"swift", "py", "md", "sh", "zsh", "yml", "yaml", "kt", "kts"}
# Files where a marker or flag can be real code (a string literal on a code line).
CODE_EXT = {"swift", "kt", "kts", "js", "py", "sh", "zsh", "yml", "yaml"}
# A path claim needs one of these: runtime and generated files (json, plist, jsonl)
# are untracked on purpose, and would fail on every mention.
PATH_EXT = {"swift", "py", "md", "sh", "zsh", "yml", "yaml", "kt", "kts", "toml", "html", "css", "js"}
SKIP_TOKEN = "claims: skip"

_SPAN = re.compile(r"`([^`\n]+)`")
_MARKER = re.compile(r"^[a-z][a-z0-9_\-]*(?: [a-z0-9_\-]+)+:$")
_FLAG = re.compile(r"^-([a-z][a-z0-9]*[A-Z][A-Za-z0-9]*)(?:[ =].*)?$")
_LINE_SUFFIX = re.compile(r"(?::\d+(?:[:-]\d+)?|#L\d+.*)$")
_NOT_A_PATH = re.compile(r"[\s*<>{}$|()\[\]~'\"]|://")
_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


@dataclass(frozen=True)
class Claim:
    kind: str  # "path" | "marker" | "flag"
    token: str


# --------------------------------------------------------------------------- #
# Pure helpers (unit-tested)
# --------------------------------------------------------------------------- #


def _ext(path: str) -> str:
    base = path.rsplit("/", 1)[-1]
    return base.rsplit(".", 1)[-1].lower() if "." in base else ""


def added_lines(diff: str) -> list[tuple[str, int, str]]:
    """(path, new line number, text) for every line a unified diff adds."""
    out: list[tuple[str, int, str]] = []
    path: str | None = None
    n = 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            target = raw[4:]
            path = target[2:] if target.startswith("b/") else None  # /dev/null: a deletion
        elif raw.startswith(("--- ", "diff --git")):
            continue
        elif m := _HUNK.match(raw):
            n = int(m.group(1))
        elif path is None:
            continue
        elif raw.startswith("+"):
            out.append((path, n, raw[1:]))
            n += 1
        elif raw.startswith(" "):
            n += 1
    return out


def checked_file(path: str) -> bool:
    """Code, docs and workflows; not eval artifacts, and not tests (their strings are fixtures)."""
    p = f"/{path}"
    base = p.rsplit("/", 1)[-1]
    if "/docs/evals/" in p or "/Tests/" in p or base.startswith("test_"):
        return False
    return _ext(path) in CHECKED_EXT


def _classify(span: str) -> Claim | None:
    if _MARKER.match(span):
        return Claim("marker", span)
    if fm := _FLAG.match(span):
        return Claim("flag", fm.group(1))
    token = _LINE_SUFFIX.sub("", span)
    if _NOT_A_PATH.search(token) or token.startswith("/"):
        return None
    if token.endswith("/") and "/" in token[:-1]:
        return Claim("path", token)
    if "/" not in token.rstrip("/") and token.count(".") != 1:
        return None  # `Foo.<T>.swift`-shaped or a bare word
    if _ext(token) in PATH_EXT and not token.startswith("."):
        return Claim("path", token)
    return None


def extract_claims(line: str) -> list[Claim]:
    if SKIP_TOKEN in line:
        return []
    return [c for span in _SPAN.findall(line) if (c := _classify(span.strip()))]


def path_resolves(token: str, tracked: Iterable[str]) -> bool:
    t = token.removeprefix("./")
    if t.endswith("/"):
        d = "/" + t.strip("/") + "/"
        return any(d in "/" + p for p in tracked)
    return any(p == t or p.endswith("/" + t) for p in tracked)


def _is_code_line(path: str, line: str) -> bool:
    ext = _ext(path)
    if ext not in CODE_EXT:
        return False
    s = line.lstrip()
    if ext in {"swift", "kt", "kts", "js"}:
        return not s.startswith(("//", "/*", "*"))
    return not s.startswith("#")


def _quotes(path: str) -> str:
    return '"' if _ext(path) in {"swift", "kt", "kts", "js"} else "\"'"


def marker_in_code(path: str, line: str, marker: str) -> bool:
    """The marker sits inside a string literal (an odd count of quotes before it)."""
    if not _is_code_line(path, line):
        return False
    at = line.find(marker)
    if at < 0:
        return False
    before = line[:at].replace('\\"', "").replace("\\'", "")
    return any(before.count(q) % 2 == 1 for q in _quotes(path))


def flag_in_code(path: str, line: str, name: str) -> bool:
    """The flag's bare name is an exact string literal ("name", "-name" or "--name")."""
    if not _is_code_line(path, line):
        return False
    return re.search(rf"[\"']-{{0,2}}{re.escape(name)}[\"']", line) is not None


def findings(
    added: Iterable[tuple[str, int, str]],
    tracked: Iterable[str],
    in_code: Callable[[Claim], bool],
) -> list[tuple[str, int, Claim]]:
    """Every claim on an added line of a checked file that does not resolve."""
    tracked = list(tracked)
    out = []
    for path, n, text in added:
        if not checked_file(path):
            continue
        for c in extract_claims(text):
            ok = path_resolves(c.token, tracked) if c.kind == "path" else in_code(c)
            if not ok:
                out.append((path, n, c))
    return out


# --------------------------------------------------------------------------- #
# I/O (verify-by-run)
# --------------------------------------------------------------------------- #


def _git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def _code_resolver() -> Callable[[Claim], bool]:
    cache: dict[Claim, bool] = {}

    def in_code(c: Claim) -> bool:
        if c not in cache:
            hits = subprocess.run(
                ["git", "grep", "-n", "-I", "-F", "-e", c.token],
                capture_output=True, text=True, check=False,  # exit 1 = no match, not an error
            ).stdout.splitlines()
            test = marker_in_code if c.kind == "marker" else flag_in_code
            cache[c] = any(
                test(p, text, c.token)
                for p, _, text in (h.split(":", 2) for h in hits if h.count(":") >= 2)
            )
        return cache[c]

    return in_code


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--range", default="origin/master...HEAD",
                    help="git diff range whose ADDED lines are checked")
    args = ap.parse_args(argv[1:])

    os.chdir(_git("rev-parse", "--show-toplevel").strip())
    added = added_lines(_git("diff", "-U0", "--no-color", "--no-ext-diff", args.range))
    tracked = _git("ls-files").splitlines()
    bad = findings(added, tracked, _code_resolver())
    total = sum(len(extract_claims(t)) for p, _, t in added if checked_file(p))

    if not bad:
        print(f"✓ {total} claim(s) on added lines resolve against the tree ({args.range}).")
        return 0
    print(f"❌ {len(bad)} of {total} claim(s) on added lines name what the tree doesn't have:")
    for path, n, c in bad:
        where = {"path": "no tracked file", "marker": "no string literal in code",
                 "flag": "no string literal in code"}[c.kind]
        print(f"  {path}:{n}: {c.kind} `{c.token}` — {where}")
    print("\nFix: make the claim true, correct the text, or add `claims: skip` to a line that "
          "names something on purpose absent.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
