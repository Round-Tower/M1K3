#!/usr/bin/env python3
"""The company is Round Tower Software Ltd: fail CI on the old "Software Studios" name (#574).

Kev, 2026-10-11: the registered name is Round Tower Software Ltd. Search engines and AI agents
read the site and the legal files, and they described the company by the old name because the
repo still used it. This scans every tracked text file and fails on the old name, matched
across a line break too. Two kinds of mention stay:

* Apple's signing certificates. Their names carry the Apple account's legal entity, which keeps
  the old name until the apps move to the new account, so "Developer ID Application: …" and
  "Apple Distribution: …" are still literally true.
* Dated provenance. An HTML comment, or a markdown `*Signed: …*` / `*Review: …*` paragraph,
  records what was true when it was written.

    python3 tools/ci/check_company_name.py      # from macos/, as the guards job runs it

Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.9 (pinned in test_check_company_name.py).
Prior: none (new file).
"""
from __future__ import annotations

import re
import subprocess
import sys

OLD_NAME = re.compile(r"software\s+studios", re.IGNORECASE)
APPLE_CERT = re.compile(
    r"(Developer ID Application|Apple Distribution|Apple Development):\s+Round\s+Tower\s+Software\s+Studios",
    re.IGNORECASE,
)
HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
MD_PROVENANCE = re.compile(r"\*(?:Signed|Review):[^*]*\*")
SELF = ("macos/tools/ci/check_company_name.py", "macos/tools/ci/test_check_company_name.py")


def scannable(path: str) -> bool:
    return path not in SELF


def _blank(match: re.Match[str]) -> str:
    """Remove a region but keep its line breaks, so line numbers still match the file."""
    return "\n" * match.group(0).count("\n")


def offenders(path: str, text: str) -> list[tuple[int, str]]:
    """(line number, line) for each place the old name appears outside the two exceptions."""
    if path.endswith((".html", ".plist", ".xml", ".md")):
        text = HTML_COMMENT.sub(_blank, text)
    if path.endswith(".md"):
        text = MD_PROVENANCE.sub(_blank, text)
    text = APPLE_CERT.sub(lambda m: re.sub(r"\S", "x", m.group(0)), text)
    lines = text.split("\n")
    found: list[tuple[int, str]] = []
    for match in OLD_NAME.finditer(text):
        number = text.count("\n", 0, match.start()) + 1
        if not found or found[-1][0] != number:
            found.append((number, lines[number - 1]))
    return found


def main() -> int:
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True,
                          text=True).stdout.strip()
    paths = subprocess.run(["git", "ls-files"], check=True, capture_output=True, text=True, cwd=root).stdout.split("\n")
    bad = 0
    for path in filter(None, paths):
        if not scannable(path):
            continue
        try:
            with open(f"{root}/{path}", encoding="utf-8") as handle:
                text = handle.read()
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue  # binary files, submodules, files deleted in the working tree
        for number, line in offenders(path, text):
            print(f"{path}:{number}: the old company name — say Round Tower Software Ltd: {line.strip()[:120]}")
            bad += 1
    if bad:
        print(f"{bad} mention(s) of the old name (#574). Apple certificate names and dated provenance are exempt.")
        return 1
    print("company name: Round Tower Software Ltd everywhere it is claimed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
