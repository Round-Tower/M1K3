#!/usr/bin/env python3
"""Render the M1K3 "M" brand mark from its single source-of-truth pixel map.

The mark is the leading glyph of the M1K3 wordmark, kept exactly: a 5×5 pixel
matrix, 13 cells on. Everything downstream — the app-icon glass layer, the
website favicon, the brand sheet — is a render of THIS map, so the shape can
never drift between surfaces.

Outputs (into this directory):
  m-mark-white.svg / m-mark-black.svg   vector source (viewBox 500×700)
  m-icon-layer-1024.png                 icon glass layer, glyph centred @64% h
  preview-*.png                         brand-sheet swatches

The icon layer is ALSO copied into ../../M1K3.icon/Assets/M-mark.png by the
--install flag (that copy is the tracked icon source Icon Composer consumes).

Reviewed: Kev + claude-opus-4-8, 2026-08-23 — reduced 5×7/17 → 5×5/13.
Signed: Kev + claude-opus-4-8, 2026-08-20, Confidence 0.9 (the ON-map is read
directly off the wordmark's own M; the compiled icon was verified in the built
bundle, not merely rendered here). Prior: Unknown (wordmark art predates sig).
"""
import os
import shutil
import sys

from PIL import Image, ImageDraw

# The one source of truth: which cells of the 5×7 grid are "on".
#   █ · · · █
#   █ █ · █ █
#   █ · █ · █
#   █ · · · █
#   █ · · · █
ON = [
    (0, 0), (4, 0),
    (0, 1), (1, 1), (3, 1), (4, 1),
    (0, 2), (2, 2), (4, 2),
    (0, 3), (4, 3),
    (0, 4), (4, 4),
]
COLS, ROWS = 5, 5
HERE = os.path.dirname(os.path.abspath(__file__))


def render_mark(cell, color=(255, 255, 255, 255), gap_frac=0.08, radius_frac=0.06):
    """A tight-bbox raster of the mark (width 5·cell, height 7·cell)."""
    gap, block, rad = int(cell * gap_frac), cell - int(cell * gap_frac), int(cell * radius_frac)
    img = Image.new("RGBA", (COLS * cell, ROWS * cell), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for c, r in ON:
        x0, y0 = c * cell + gap // 2, r * cell + gap // 2
        d.rounded_rectangle([x0, y0, x0 + block, y0 + block], radius=rad, fill=color)
    return img


def centered(mark, square=1024, frac=0.64):
    """Centre the mark on a transparent square; glyph height = frac of square."""
    th = int(square * frac)
    tw = int(mark.width * th / mark.height)
    m = mark.resize((tw, th), Image.LANCZOS)
    cv = Image.new("RGBA", (square, square), (0, 0, 0, 0))
    cv.alpha_composite(m, ((square - tw) // 2, (square - th) // 2))
    return cv


def svg(color):
    """The vector source of truth — pure rounded rects, cell 100, gap 8, rx 6."""
    rects = "\n    ".join(
        f'<rect x="{c*100+4}" y="{r*100+4}" width="92" height="92" rx="6" fill="{color}"/>'
        for c, r in ON
    )
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {COLS*100} {ROWS*100}" '
        f'role="img" aria-label="M1K3">\n    {rects}\n</svg>\n'
    )


def main(install=False):
    out = lambda name: os.path.join(HERE, name)
    open(out("m-mark-white.svg"), "w").write(svg("#FFFFFF"))
    open(out("m-mark-black.svg"), "w").write(svg("#0A0A0C"))

    layer = centered(render_mark(200), 1024, 0.64)
    layer.save(out("m-icon-layer-1024.png"))

    # brand-sheet swatches
    def flat(bg_rgb, mark, square=512, frac=0.66):
        im = Image.new("RGBA", (square, square), bg_rgb + (255,))
        im.alpha_composite(centered(mark, square, frac))
        return im.convert("RGB")

    flat((10, 10, 12), render_mark(120), 512).save(out("preview-white-on-dark.png"))
    flat((245, 245, 247), render_mark(120, (10, 10, 12, 255)), 512).save(out("preview-black-on-light.png"))

    if install:
        dest = os.path.join(HERE, "..", "..", "..", "M1K3.icon", "Assets", "M-mark.png")
        shutil.copyfile(out("m-icon-layer-1024.png"), dest)
        print("installed →", os.path.normpath(dest))
    print("rendered mark (13/25 pixels) into", HERE)


if __name__ == "__main__":
    main(install="--install" in sys.argv)
