#!/usr/bin/env python3
"""Flatten a PNG to RGB (no alpha) in place. App Store Connect rejects
screenshots with an alpha channel — silently, in some tooling."""
import sys
from PIL import Image

for f in sys.argv[1:]:
    im = Image.open(f)
    if im.mode != "RGB":
        bg = Image.new("RGB", im.size, (5, 5, 5))
        if "A" in im.mode:
            bg.paste(im.convert("RGBA"), mask=im.convert("RGBA").split()[3])
        else:
            bg.paste(im.convert("RGB"))
        bg.save(f, "PNG", optimize=True)
