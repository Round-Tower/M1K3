#!/usr/bin/env python3
"""Fail when App Store copy in fastlane/metadata_mac breaks Apple's limits.

The store copy lives here so it can be riffed on in any language. Apple
counts CHARACTERS, not bytes, and rejects the whole `fastlane mac metadata`
upload when one field runs over. This catches that on the PR instead, with
the file and the count. Every locale also needs a support URL: its absence
blocks App Review (seven locales had none until 2026-09-14).

    python3 check_store_metadata.py [METADATA_DIR]

Defaults to the repo's macos/fastlane/metadata_mac. Read-only. The pure
helpers are pinned in test_check_store_metadata.py.

Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.9 (limits from Apple's
App Store Connect field reference; one trailing newline is ignored because
deliver strips it). Prior: Unknown
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# Apple's per-field character limits for App Store Connect metadata.
LIMITS = {
    "name": 30,
    "subtitle": 30,
    "keywords": 100,
    "promotional_text": 170,
    "description": 4000,
    "release_notes": 4000,
}

# A locale folder is "en-US", "ja", "zh-Hans", "pt-BR" — not "review_information".
_LOCALE = re.compile(r"^[a-z]{2,3}(-[A-Za-z]{2,4})?$")


def problems(root: Path) -> list[str]:
    found: list[str] = []
    for locale in sorted(p for p in root.iterdir() if p.is_dir() and _LOCALE.match(p.name)):
        for field, limit in LIMITS.items():
            f = locale / f"{field}.txt"
            if not f.exists():
                continue
            text = f.read_text(encoding="utf-8").removesuffix("\n")
            if len(text) > limit:
                found.append(f"{locale.name}/{f.name}: {len(text)}/{limit} characters")
        url = locale / "support_url.txt"
        if not url.exists() or not url.read_text(encoding="utf-8").strip():
            found.append(f"{locale.name}: no support_url.txt (App Review blocks a locale without one)")
    return found


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "fastlane" / "metadata_mac"
    found = problems(root)
    for p in found:
        print(f"::error::{p}")
    locales = [p.name for p in root.iterdir() if p.is_dir() and _LOCALE.match(p.name)]
    print(f"{len(locales)} locales checked, {len(found)} problem(s)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
