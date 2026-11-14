#!/usr/bin/env python3
"""File the accessibility audit's reports by screen, out of an xcresult attachment export.

    a11y_collect.py <export-dir> <out-dir>

`xcresulttool export attachments` writes every attachment under an opaque file name plus a
manifest.json that maps it to the name the test gave it. The audit suites
(UITests/Screengrab*/AccessibilityAudit*) name theirs `a11y-<screen>`; this copies each one to
`<out-dir>/<screen>.txt` and ignores everything else XCTest attached (screenshots, element
trees, recordings). `tools/dev/a11y_audit.sh` runs it and prints the result.

Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85 (pinned by test_a11y_collect.py; the
manifest shape is the one tools/screengrab/capture.sh already reads), Prior: Unknown
Review: Kev + claude-fable-5.2, 2026-11-14 — also files each screen's picture (`a11y-shot-<screen>`)
as `<screen>.png`: the runner's sandbox cannot write it there itself, and a11y_contrast.py measures on it.
Review: Kev + claude-fable-5.2, 2026-11-14 — element trees (`a11y-tree-<screen>`) go to `trees/`: the
first phone run filed them as reports named `tree-<screen>` and printed 600 lines of tree.
"""

from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path

PREFIX = "a11y-"
#: The picture the Mac suite takes of each screen, filed beside its report as `<screen>.png`.
SHOT_PREFIX = "a11y-shot-"
#: The window's element tree, filed as `trees/<screen>.txt`: for reading, never printed as a report.
TREE_PREFIX = "a11y-tree-"
#: A screen is a plate name: lowercase words joined by hyphens. Anything else is not ours to write.
_SCREEN = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")


def screen_of(name: str) -> str | None:
    """`a11y-brain-at-home_0_77.txt` -> `brain-at-home`; None for any other attachment."""
    if not name.startswith(PREFIX) or not name.endswith(".txt"):
        return None
    screen = name[len(PREFIX) :].removesuffix(".txt").split("_")[0]
    return screen if _SCREEN.fullmatch(screen) else None


def shot_of(name: str) -> str | None:
    """`a11y-shot-chat_0_9F.png` -> `chat`; None for any other attachment."""
    if not name.startswith(SHOT_PREFIX) or not name.endswith(".png"):
        return None
    screen = name[len(SHOT_PREFIX) :].removesuffix(".png").split("_")[0]
    return screen if _SCREEN.fullmatch(screen) else None


def tree_of(name: str) -> str | None:
    """`a11y-tree-chat_0_9F.txt` -> `chat`; None for any other attachment."""
    if not name.startswith(TREE_PREFIX) or not name.endswith(".txt"):
        return None
    screen = name[len(TREE_PREFIX) :].removesuffix(".txt").split("_")[0]
    return screen if _SCREEN.fullmatch(screen) else None


def collect(export_dir: Path, out_dir: Path) -> list[str]:
    """Copy each audit report to `<out_dir>/<screen>.txt`; return the screens filed, in manifest order."""
    filed: list[str] = []
    manifest = json.loads((export_dir / "manifest.json").read_text())
    for test in manifest if isinstance(manifest, list) else []:
        for attachment in (test.get("attachments") if isinstance(test, dict) else None) or []:
            if not isinstance(attachment, dict):
                continue
            exported = attachment.get("exportedFileName")
            named = attachment.get("suggestedHumanReadableName") or exported
            # A bare file name only: the manifest is xcresulttool's, but nothing here reads outside the export.
            if not isinstance(exported, str) or not isinstance(named, str) or Path(exported).name != exported:
                continue
            source = export_dir / exported
            if not source.is_file():
                continue
            if (pictured := shot_of(named)) is not None:
                out_dir.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, out_dir / f"{pictured}.png")
                continue
            if (treed := tree_of(named)) is not None:
                (out_dir / "trees").mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, out_dir / "trees" / f"{treed}.txt")
                continue
            screen = screen_of(named)
            if screen is None:
                continue
            out_dir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, out_dir / f"{screen}.txt")
            filed.append(screen)
    return filed


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    for screen in collect(Path(argv[1]), Path(argv[2])):
        print(f"report {screen}.txt")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
