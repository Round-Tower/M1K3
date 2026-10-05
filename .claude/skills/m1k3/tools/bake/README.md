# Baking the companion frames

`assets/frames`, `assets/braille`, `assets/svg` and `assets/manifest.json` are
baked output. Regenerate them here; never hand-edit them.

What it needs, once, in this folder:

```sh
npm pack three@0.160.0 && mkdir -p package && tar -xzf three-0.160.0.tgz
cp /path/to/glTF-Sample-Assets/Models/Fox/glTF-Binary/Fox.glb .
npx playwright install chromium          # or point PLAYWRIGHT_BROWSERS_PATH at one
```

Then:

```sh
npx http-server -p 8765 -s . &
node bake.mjs
```

`bake.html` loads the GLB with three.js, frames it with a 26° camera at a
three-quarter angle, and renders every clip at 16 frames per second of clip
(12 to 48 frames) into 192 × 96 strips with alpha, in two looks: the model's
own textures, and the phosphor treatment (a wireframe over a dark fill, an
approximation of the app's shader). `bake.mjs` drives headless Chromium through
Playwright and writes one PNG per frame, each frame reduced to braille cells
at the band's size (24 × 6) and a pane's (48 × 12), an 80 × 40 strip of at
most 24 frames for the desktop's SMIL sprite, and the manifest.

Another companion is the same run with its GLB and its clip names; the
app's `macos/tools/companion-pipeline/export_clips.py` is where its USDZ
clips come from, and the attribution goes in `../../assets/ATTRIBUTION.md`.
