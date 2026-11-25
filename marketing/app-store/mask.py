#!/usr/bin/env python3
"""Plate retouch: paint over capture defects before a render, never the plate itself.

    python3 mask.py '<json>'   # [{"src": ..., "dst": ..., "masks": [...]}, ...]

A mask is {"rect": [x, y, w, h]} in plate pixels, plus:
  "fill": [r, g, b]   paint the rect that colour, or
  "fill": "row"       per row, blend from the pixel left of the rect to the one right of it
                      (a badge or switch on a gradient card disappears into the card),
  "fill": "left"      per row, the pixel left of the rect (scanline backdrops), and
  "key": "blue"       only repaint pixels bluer than the backdrop (a ghost caption behind a
                      mesh: the mesh is grey-green, the caption blue-grey, so the mesh stays),
  "key": "bright"     only repaint pixels with every channel above "min" (default 90; a solid grey face on a
                      wireframe drawn on black: the face goes, the black around it stays), and
  "key": "solid"      only repaint the SOLID bright regions: pixels above "min" (default 100) that survive a
                      morphological opening of "open" px (default 7), then shrunk by "rim" px (default 2).
                      A wireframe's 2-3 px lines are thinner than the opening, so they stay; a filled
                      face goes, and its outline survives as the rim (QA r4: the iPad fox's grey faces),
  "key": "neutral"    only repaint NEUTRAL grey pixels (|b - r| <= "tol", default 1) brighter than "min"
                      (default 24): the wireframe fox is neutral grey, the iOS secondary label and its
                      icons are tinted (b - r 2-6), so the lattice goes and the text it ran behind stays
                      (QA r6: the fox across the ask-documents source chip and action row),
  "fill": "col"       per column, the median of that column over the clean rows "ref": [y0, y1] (per
                      channel): a bar with blurred ghosts under its glass becomes the bar's own clean
                      tone, its horizontal gradient kept; "fadeTop": [y, n] ramps rows y..y+n up from black
                      (a banded-out status bar above meets the bar as a soft edge, not a step),
  "skipAbove": n      never repaint a pixel whose every channel is above n (a title over the bar),
  "keep": [[x0, y0, x1, y1, r], ...]
                      never repaint inside these rounded rects (cards): the rect is painted
                      everywhere around them, corner wedges included.
render.js writes the masked copies to out/.plates/ and points the frames at them.
"""
import json
import os
import sys

from PIL import Image, ImageFilter

for job in json.loads(sys.argv[1]):
    im = Image.open(job["src"]).convert("RGB")
    px = im.load()
    W, H = im.size
    for m in job["masks"]:
        x, y, w, h = m["rect"]
        fill = m.get("fill", "row")
        key = m.get("key")
        keep = m.get("keep", [])

        def kept(px_, py_):
            for x0, y0, x1, y1, r in keep:
                if x0 <= px_ < x1 and y0 <= py_ < y1:
                    cx = min(max(px_, x0 + r), x1 - 1 - r)
                    cy = min(max(py_, y0 + r), y1 - 1 - r)
                    if (px_ - cx) ** 2 + (py_ - cy) ** 2 <= r * r:
                        return True
            return False
        solid = None
        if key == "solid":
            k, rim, lo = m.get("open", 7), m.get("rim", 2), m.get("min", 100)
            box = (max(0, x), max(0, y), min(W, x + w), min(H, y + h))
            g = im.crop(box).convert("L").point(lambda v: 255 if v > lo else 0)
            g = g.filter(ImageFilter.MinFilter(k)).filter(ImageFilter.MaxFilter(k))
            if rim:
                g = g.filter(ImageFilter.MinFilter(2 * rim + 1))
            gp, solid = g.load(), set()
            for yy in range(box[3] - box[1]):
                for xx in range(box[2] - box[0]):
                    if gp[xx, yy]:
                        solid.add((box[0] + xx, box[1] + yy))
        if fill == "col":
            cols, (r0, r1) = {}, m["ref"]
            for xx in range(max(0, x), min(W, x + w)):
                c = [px[xx, yy] for yy in range(r0, r1)]
                cols[xx] = tuple(sorted(v[i] for v in c)[len(c) // 2] for i in range(3))
            fy, fn = m.get("fadeTop", [y, 0])
        for yy in range(max(0, y), min(H, y + h)):
            if fill in ("row", "left"):
                a = px[max(0, x - 2), yy]
                b = a if fill == "left" else px[min(W - 1, x + w + 1), yy]
            for xx in range(max(0, x), min(W, x + w)):
                if keep and kept(xx, yy):
                    continue
                if key == "blue":
                    r, g, bl = px[xx, yy]
                    if not (bl - r > 14 and bl > 30):
                        continue
                if key == "bright" and min(px[xx, yy]) <= m.get("min", 90):
                    continue
                if key == "neutral":
                    r, g, bl = px[xx, yy]
                    if abs(bl - r) > m.get("tol", 1) or max(r, g, bl) <= m.get("min", 24):
                        continue
                if solid is not None and (xx, yy) not in solid:
                    continue
                if "skipAbove" in m and min(px[xx, yy]) > m["skipAbove"]:
                    continue
                if fill == "col":
                    t = 1 if not fn or yy >= fy + fn else max(0, yy - fy) / fn
                    px[xx, yy] = tuple(round(v * t) for v in cols[xx])
                elif fill in ("row", "left"):
                    t = (xx - x) / max(1, w - 1)
                    px[xx, yy] = tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))
                else:
                    px[xx, yy] = tuple(fill)
    os.makedirs(os.path.dirname(job["dst"]), exist_ok=True)
    im.save(job["dst"], "PNG")
    print(f"masked {os.path.basename(job['src'])} → {job['dst']} ({len(job['masks'])})")
