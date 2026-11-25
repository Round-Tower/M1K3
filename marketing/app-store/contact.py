#!/usr/bin/env -S uv run --quiet --script
# /// script
# dependencies = ["pillow"]
# ///
"""Contact sheet: the whole set at thumbnail size, roughly how the store shows it.
    python3 contact.py out/ios/en-US contact-ios.png
If you can't tell what the app does from this sheet, fix that before polishing."""
import glob, os, sys
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(src, "*.png")))
ims = [Image.open(f) for f in files]
w, h = ims[0].size
portrait = h > w
tw = 440 if portrait else 700
th = round(tw * h / w)
cols = 4 if portrait else 2
rows = -(-len(ims) // cols)
gap = 24
sheet = Image.new("RGB", (cols * tw + (cols + 1) * gap, rows * th + (rows + 1) * gap), (18, 18, 18))
for i, im in enumerate(ims):
    t = im.resize((tw, th), Image.LANCZOS)
    x = gap + (i % cols) * (tw + gap)
    y = gap + (i // cols) * (th + gap)
    sheet.paste(t, (x, y))
sheet.save(dst)
print(f"{dst}  {sheet.size[0]}×{sheet.size[1]}  ({len(ims)} frames)")
