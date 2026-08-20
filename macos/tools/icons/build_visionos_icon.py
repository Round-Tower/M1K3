#!/usr/bin/env python3
"""Build the visionOS layered app icon (AppIcon.solidimagestack).

Icon Composer has no visionOS support (Xcode 26.x), so this is hand-authored.
visionOS wants a 1-3 layer stack, each layer a 1024x1024 PNG:
  Back   - MUST be fully opaque (actool errors otherwise)
  Middle - transparent; this is what sells the parallax depth
  Front  - transparent; the mark itself
The system applies the circular mask and the 3D parallax; we do not pre-crop.

Direction (Kev's call, 2026-07-20): B - the pixel M monogram, subtle glow.
Three candidates were rendered at 420/190/90px under the circular mask; Kev chose
the monogram over the full wordmark, trading name-recognition for a shape that
survives at 40px. The wordmark is a 3:1 mark and reads as a stripe in a circle.

Signed: Kev + claude-opus-4-8, 2026-07-20, Confidence 0.85, Prior: Unknown
  Verified: M1K3visionOS builds clean and the compiled Assets.car carries
  AppIcon/{Back,Middle,Front}/Content at LayerIndex 0/1/2. NOT verified: how the
  parallax actually feels on real Vision Pro hardware - that needs a headset, and
  the layer separation is a judgement call until someone wears it. The catalog
  JSON shape (idiom "vision", scale "2x", Content.imageset per layer) was
  reconstructed rather than copied from an Xcode template; it compiles, which is
  strong but not the same as being Apple's canonical form.
"""
from PIL import Image, ImageDraw, ImageFilter
import json
import os
import shutil

# Paths resolve from this file's location (macos/tools/icons/) so the script
# works from any checkout and any working directory.
MACOS_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(MACOS_DIR, "M1K3.icon", "Assets", "M-mark.png")
DEST = os.path.join(MACOS_DIR, "M1K3visionOS", "Assets.xcassets")
STACK = os.path.join(DEST, "AppIcon.solidimagestack")
S = 1024
INFO = {"author": "xcode", "version": 1}

src = Image.open(SRC).convert("RGBA")
w, h = src.size

# --- isolate the leading pixel "M" -------------------------------------------
alpha = src.getchannel("A")
cols = [alpha.crop((x, 0, x + 1, h)).getbbox() is not None for x in range(w)]
runs, start = [], None
for x, on in enumerate(cols + [False]):
    if on and start is None:
        start = x
    elif not on and start is not None:
        runs.append((start, x))
        start = None
merged = []
for r in runs:
    if merged and r[0] - merged[-1][1] < 60:
        merged[-1] = (merged[-1][0], r[1])
    else:
        merged.append(r)
assert merged, "no glyphs found in wordmark"
mono = src.crop((merged[0][0], 0, merged[0][1], h))
mono = mono.crop(mono.getbbox())
print(f"monogram glyph: {mono.size} (from column group {merged[0]})")

# --- layers ------------------------------------------------------------------
back = Image.new("RGBA", (S, S), (0, 0, 0, 255))          # opaque, as required

middle = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(middle).ellipse([S * 0.16, S * 0.16, S * 0.84, S * 0.84],
                               fill=(90, 120, 160, 90))
middle = middle.filter(ImageFilter.GaussianBlur(110))      # subtle phosphor bloom

front = Image.new("RGBA", (S, S), (0, 0, 0, 0))
tw = int(S * 0.34)                                         # safe inside the circle
th = round(mono.height * tw / mono.width)
front.paste(mono.resize((tw, th), Image.LANCZOS),
            ((S - tw) // 2, (S - th) // 2),
            mono.resize((tw, th), Image.LANCZOS))

assert back.getchannel("A").getextrema() == (255, 255), "back layer must be fully opaque"

# --- emit the catalog --------------------------------------------------------
if os.path.exists(STACK):
    shutil.rmtree(STACK)
os.makedirs(STACK)


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


# Layer order in Contents.json is front-to-back.
layers = [("Front", front), ("Middle", middle), ("Back", back)]
write_json(os.path.join(STACK, "Contents.json"),
           {"info": INFO, "layers": [{"filename": f"{n}.solidimagestacklayer"} for n, _ in layers]})

for name, img in layers:
    ldir = os.path.join(STACK, f"{name}.solidimagestacklayer")
    cdir = os.path.join(ldir, "Content.imageset")
    os.makedirs(cdir)
    write_json(os.path.join(ldir, "Contents.json"), {"info": INFO})
    png = f"{name.lower()}.png"
    img.save(os.path.join(cdir, png))
    write_json(os.path.join(cdir, "Contents.json"),
               {"images": [{"filename": png, "idiom": "vision", "scale": "2x"}], "info": INFO})

write_json(os.path.join(DEST, "Contents.json"), {"info": INFO})
print("wrote", STACK)
for root, _, files in os.walk(DEST):
    for f in sorted(files):
        print("  ", os.path.relpath(os.path.join(root, f), DEST))
