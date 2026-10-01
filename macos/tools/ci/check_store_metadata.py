#!/usr/bin/env python3
"""Fail when App Store copy in fastlane/metadata_{mac,ios} breaks Apple's limits.

The store copy lives here so it can be riffed on in any language. Apple
counts CHARACTERS, not bytes, and rejects the whole `fastlane mac metadata`
upload when one field runs over. This catches that on the PR instead, with
the file and the count. Every locale also needs a support URL: its absence
blocks App Review (seven locales had none until 2026-09-14).

    python3 check_store_metadata.py [METADATA_DIR]

Defaults to every platform folder under macos/fastlane (metadata_mac and
metadata_ios), which adds two record-level checks: the shared fields (name,
subtitle, privacy URL live on the app record, not the version) must match
across platforms, and no storefront may be sold a device it isn't — the
iPhone listing carried "runs entirely on your Mac" from launch until
2026-10-01. Read-only. The pure helpers are pinned in
test_check_store_metadata.py.

Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.9 (limits from Apple's
App Store Connect field reference; one trailing newline is ignored because
deliver strips it). Prior: Unknown
Review: Kev + claude-opus-5.5, 2026-10-01 — metadata_ios joins; two record-level
checks: shared fields (name/subtitle/privacy URL) identical across platform
folders, and no device claims (shared fields name no device; the iPhone copy
names the Mac only on a Brain at Home line). The regex avoids \b so 在Mac上
is caught. Confidence now 0.85 — the claim check is a line heuristic: a
false Mac claim sharing a line with "Brain at Home" would slip past it.
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

# Fields stored once on the app record (appInfoLocalizations) and shown by every
# platform's storefront. Two folders disagreeing means the last lane to push wins.
SHARED_FIELDS = ("name", "subtitle", "privacy_url")

# Copy the iPhone/iPad storefront shows. Name + subtitle are checked on every
# platform because they are shared (see SHARED_FIELDS).
VERSION_FIELDS = ("description", "promotional_text", "release_notes")  # keywords: checked on every platform

# "Mac" as a word in any script: no Latin letter before it (Python's \b sees no
# boundary between 在 and M), no lowercase after (Machine, macro). MacBook counts.
_MAC = re.compile(r"(?<![A-Za-z])(?:i?Macs?(?![a-z])|macOS)")
# Case-insensitive: keywords are conventionally lowercase (`iphone,mac`).
_ANY_DEVICE = re.compile(r"(?<![A-Za-z])(?:i?Macs?(?![a-z])|macOS|iPhone|iPad|Vision Pro|visionOS)", re.IGNORECASE)
# The honest exception on an iPhone listing: borrowing the Mac's brain over the LAN.
_BRAIN_AT_HOME = "Brain at Home"

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


def _locales(root: Path) -> list[Path]:
    return sorted(p for p in root.iterdir() if p.is_dir() and _LOCALE.match(p.name))


def _read(f: Path) -> str | None:
    return f.read_text(encoding="utf-8").removesuffix("\n") if f.exists() else None


def device_claims(root: Path, platform: str) -> list[str]:
    """Lines that sell a storefront the wrong device.

    Shared fields and keywords may name no device at all; the iPhone
    listing's own copy may name the Mac only on a Brain at Home line.
    """
    found: list[str] = []
    for locale in _locales(root):
        for field in ("name", "subtitle"):
            text = _read(locale / f"{field}.txt")
            if text and (m := _ANY_DEVICE.search(text)):
                found.append(f"{locale.name}/{field}.txt: '{m.group()}' on a field every platform's storefront shows")
        # Guideline 5.2.5 (Apple product names in metadata) flagged "Mac" in two
        # subtitles on 2026-09-23; keywords are metadata under the same rule.
        keywords = _read(locale / "keywords.txt")
        if keywords and (m := _ANY_DEVICE.search(keywords)):
            found.append(f"{locale.name}/keywords.txt: '{m.group()}' — Apple product names stay out of keywords (5.2.5)")
        if platform != "IOS":
            continue
        for field in VERSION_FIELDS:
            for line in (_read(locale / f"{field}.txt") or "").splitlines():
                if _BRAIN_AT_HOME not in line and (m := _MAC.search(line)):
                    found.append(f"{locale.name}/{field}.txt: '{m.group()}' on the iPhone listing — {line.strip()[:60]}")
    return found


def shared_drift(roots: dict[str, Path]) -> list[str]:
    """Shared fields that differ between platform folders (absence counts)."""
    found: list[str] = []
    names = sorted({loc.name for root in roots.values() for loc in _locales(root)})
    for name in names:
        for field in SHARED_FIELDS:
            values = {platform: _read(root / name / f"{field}.txt") for platform, root in roots.items()}
            if len(set(values.values())) > 1:
                shown = ", ".join(f"{k}={'missing' if v is None else repr(v)}" for k, v in values.items())
                found.append(f"{name}/{field}.txt differs across platforms (one record, one value): {shown}")
    return found


PLATFORM_DIRS = {"MAC_OS": "metadata_mac", "IOS": "metadata_ios"}


def main() -> int:
    if len(sys.argv) > 1:
        roots = {"MAC_OS": Path(sys.argv[1])}
    else:
        fastlane = Path(__file__).resolve().parents[2] / "fastlane"
        roots = {k: fastlane / v for k, v in PLATFORM_DIRS.items() if (fastlane / v).is_dir()}
    found: list[str] = []
    for platform, root in roots.items():
        found += [f"{root.name}/{p}" for p in problems(root) + device_claims(root, platform)]
    found += shared_drift(roots)
    for p in found:
        print(f"::error::{p}")
    checked = sum(len(_locales(r)) for r in roots.values())
    print(f"{checked} locales checked across {len(roots)} platform(s), {len(found)} problem(s)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
