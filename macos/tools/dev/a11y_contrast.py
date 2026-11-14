#!/usr/bin/env -S uv run --script --managed-python
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Re-measure the accessibility audit's contrast findings on each screen's own picture.

    a11y_contrast.py <report-dir>

Xcode's audit says "Contrast failed" without a number, and on this app it says it about body
text that measures 16:1 as readily as about a caption at 3.2:1 (the first Mac run, 2026-11-14:
18 of 31 contrast findings were primary text above 7:1). This reads each `<screen>.txt` the Mac
audit wrote, finds every contrast finding's frame, and measures it on `<screen>.png`: the
text is the darkest or lightest half-percent of the patch, the background is its median.

It prints one line per finding, lowest ratio first, and exits 1 when any measures under 4.5:1.

What it is not: proof. Thin text never reaches its full colour once anti-aliased, which reads
low; a stray dark or light mark in the patch (a border, a neighbouring glyph) reads high; a
patch that holds two backgrounds measures the busier one. Treat a pass well clear of the bar as
fine and anything near it, or failed, as worth a look in Accessibility Inspector.

A finding is only measured when its line carries a frame, which a labelled element's does not,
and when its screen has a WINDOW heading and a picture. Whatever was left out is counted and
named at the end, never passed over. Mac only: the phone audit writes neither.

Signed: Kev + claude-fable-5.2, 2026-11-14, Confidence 0.75 (the arithmetic is pinned by
test_a11y_contrast.py; the text/background split is a heuristic, checked by eye on seven
screens in both appearances), Prior: Unknown
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

BAR = 4.5
Frame = tuple[float, float, float, float]

_FRAME = r"\(([\d.-]+), ([\d.-]+), ([\d.-]+), ([\d.-]+)\)"
_WINDOW = re.compile(rf"^WINDOW {_FRAME}$", re.MULTILINE)
_ANY_CONTRAST = re.compile(r"^- \[contrast\] ", re.MULTILINE)
_FINDING = re.compile(rf"^- \[contrast\] (.*?) at {_FRAME}: (.*)$", re.MULTILINE)


@dataclass(frozen=True)
class Finding:
    name: str
    frame: Frame
    said: str


def window_of(report: str) -> Frame | None:
    """The window's frame from the report's `WINDOW (x, y, w, h)` heading."""
    found = _WINDOW.search(report)
    return tuple(float(v) for v in found.groups()) if found else None  # type: ignore[return-value]


def findings_of(report: str) -> list[Finding]:
    """Every contrast finding that carries a frame. A named element's finding has none."""
    return [
        Finding(name=g[0], frame=(float(g[1]), float(g[2]), float(g[3]), float(g[4])), said=g[5])
        for g in _FINDING.findall(report)
    ]


def pixel_box(frame: Frame, window: Frame, size: tuple[int, int]) -> tuple[int, int, int, int] | None:
    """The frame's box on a picture of the window, or None when it lies outside the picture."""
    scale = size[0] / window[2]
    left, top = (frame[0] - window[0]) * scale, (frame[1] - window[1]) * scale
    box = (
        max(int(left), 0),
        max(int(top), 0),
        min(int(left + frame[2] * scale), size[0]),
        min(int(top + frame[3] * scale), size[1]),
    )
    return box if box[2] > box[0] and box[3] > box[1] else None


def luminance(rgb: tuple[int, int, int]) -> float:
    """WCAG relative luminance of an sRGB pixel."""

    def channel(value: int) -> float:
        v = value / 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4

    return 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2])


def ratio(luminances: list[float]) -> float:
    """Contrast of a patch's text against its background, whichever of the two is the darker."""
    ordered = sorted(luminances)
    background = ordered[len(ordered) // 2]
    darkest = ordered[int(len(ordered) * 0.005)]
    lightest = ordered[min(int(len(ordered) * 0.995), len(ordered) - 1)]
    return max((lightest + 0.05) / (background + 0.05), (background + 0.05) / (darkest + 0.05))


def line(screen: str, name: str, measured: float | None) -> str:
    if measured is None:
        return f"{screen:<16}     –    off-picture  {name}"
    return f"{screen:<16} {measured:4.1f}:1  {'passes' if measured >= BAR else 'FAILS':<7}  {name}"


def unplaced(report: str) -> int:
    """How many contrast findings carry no frame (a labelled element's line), so cannot be measured."""
    return len(_ANY_CONTRAST.findall(report)) - len(findings_of(report))


def measure(report_dir: Path) -> tuple[list[tuple[str, str, float | None]], list[str]]:
    """Each measurable finding as (screen, name, ratio), and a note per thing left unmeasured."""
    from PIL import Image

    rows: list[tuple[str, str, float | None]] = []
    notes: list[str] = []
    for report_path in sorted(report_dir.glob("*.txt")):
        report, screen = report_path.read_text(), report_path.stem
        window, picture = window_of(report), report_path.with_suffix(".png")
        flagged = len(_ANY_CONTRAST.findall(report))
        if window is None or not picture.is_file():
            if flagged:
                missing = "no WINDOW heading" if window is None else "no picture"
                notes.append(f"{screen}: {flagged} contrast finding(s) NOT measured ({missing})")
            continue
        if left := unplaced(report):
            notes.append(f"{screen}: {left} contrast finding(s) NOT measured (a labelled element has no frame)")
        image = Image.open(picture).convert("RGB")
        for finding in findings_of(report):
            box = pixel_box(finding.frame, window, image.size)
            measured = None
            if box:
                raw = image.crop(box).tobytes()
                measured = ratio([luminance((raw[i], raw[i + 1], raw[i + 2])) for i in range(0, len(raw), 3)])
            rows.append((screen, finding.name, measured))
    return rows, notes


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    rows, notes = measure(Path(argv[1]))
    rows.sort(key=lambda row: (row[2] is None, row[2] or 0.0))
    if not rows and not notes:
        print("no contrast findings")
    for screen, name, measured in rows:
        print(line(screen, name, measured))
    for note in notes:
        print(note)
    return 1 if any(m is not None and m < BAR for _, _, m in rows) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
