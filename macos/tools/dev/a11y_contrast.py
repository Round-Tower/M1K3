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
A patch with no text in it at all (under 1.5:1) is said to be that, not a failure: the screen
moved between the audit reading the frame and the picture being taken.

What it is not: proof. Thin text never reaches its full colour once anti-aliased, which reads
low; a stray dark or light mark in the patch (a border, a neighbouring glyph) reads high; a
patch that holds two backgrounds measures the busier one. Treat a pass well clear of the bar as
fine and anything near it, or failed, as worth a look in Accessibility Inspector.

A finding is only measured when its line carries a frame and its screen has a WINDOW heading
and a picture. Whatever was left out is counted and named at the end, never passed over.

Signed: Kev + claude-fable-5.2, 2026-11-14, Confidence 0.75 (the arithmetic is pinned by
test_a11y_contrast.py; the text/background split is a heuristic, checked by eye on seven
screens in both appearances), Prior: Unknown
Review: Kev + claude-fable-5.2, 2026-11-14 — reads the frame from the finding's detail, so labelled
elements (nearly every finding on the phone) are measured, and the phone's reports are read too.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

BAR = 4.5
#: Under this a patch is flat: no text is where the finding said. The screen moved between the
#: audit reading the frame and the picture (a scrolled list), so there is nothing to judge.
FLAT = 1.5
Frame = tuple[float, float, float, float]

_FRAME = r"\(([\d.-]+), ([\d.-]+), ([\d.-]+), ([\d.-]+)\)"
_WINDOW = re.compile(rf"^WINDOW {_FRAME}$", re.MULTILINE)
_ANY_CONTRAST = re.compile(r"^- \[contrast\] ", re.MULTILINE)
#: The frame rides at the end of the detail: `…: Contrast failed (static text at (x, y, w, h))`.
_FINDING = re.compile(rf"^- \[contrast\] (.*): (.*? at {_FRAME}\))$", re.MULTILINE)
#: Reports written before 2026-11-14 carried it only in an UNLABELLED element's name.
_OLD_FINDING = re.compile(rf"^- \[contrast\] (.*?) at {_FRAME}: (.*)$", re.MULTILINE)


@dataclass(frozen=True)
class Finding:
    name: str
    frame: Frame
    said: str


def window_of(report: str) -> Frame | None:
    """The window's frame from the report's `WINDOW (x, y, w, h)` heading; None when absent or empty."""
    found = _WINDOW.search(report)
    if not found:
        return None
    frame = tuple(float(v) for v in found.groups())
    # A window that had gone (the app died, the audit did not complete) reports an empty frame:
    # that is no window to place anything on.
    return frame if frame[2] > 0 and frame[3] > 0 else None  # type: ignore[return-value]


def findings_of(report: str) -> list[Finding]:
    """Every contrast finding whose line says where its element is."""
    found: list[Finding] = []
    for line_text in report.splitlines():
        if (new := _FINDING.match(line_text)) is not None:
            name, said, *frame = new.groups()
            # An unlabelled element's name repeats the frame: keep the name a reader would say.
            name = re.sub(rf" at {_FRAME}$", "", name)
        elif (old := _OLD_FINDING.match(line_text)) is not None:
            name, *frame, said = old.groups()
        else:
            continue
        found.append(Finding(name=name, frame=tuple(float(v) for v in frame), said=said))  # type: ignore[arg-type]
    return found


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
    if measured < FLAT:
        return f"{screen:<16} {measured:4.1f}:1  no text there (the screen moved)  {name}"
    return f"{screen:<16} {measured:4.1f}:1  {'passes' if measured >= BAR else 'FAILS':<7}  {name}"


def unplaced(report: str) -> int:
    """How many contrast findings carry no frame, so cannot be measured."""
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
            notes.append(f"{screen}: {left} contrast finding(s) NOT measured (its line carries no frame)")
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
    if blank := sum(1 for _, _, m in rows if m is not None and m < FLAT):
        # Said out loud: a flat patch is nearly always a moved screen, but text too pale to
        # register would read the same, so these are unjudged, not cleared.
        print(f"{blank} contrast finding(s) NOT measured (no text at the frame: look at these by eye)")
    for note in notes:
        print(note)
    return 1 if any(m is not None and FLAT <= m < BAR for _, _, m in rows) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
