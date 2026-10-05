# Baked companion frames — attribution

These frames are renders of other people's work, used under their own licences.
Keep this file with the frames if you redistribute them.

| Files | Work | Author(s) | Licence | Source |
|---|---|---|---|---|
| `frames/fox-*`, `braille/fox-*`, `svg/fox-*` | Fox, Khronos glTF Sample Assets | model: PixelMannen · rig + Survey/Walk/Run animations: tomkranis | model [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) · rig/animations [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/Fox |
| `frames/phosphor-*`, `braille/phosphor-*`, `svg/phosphor-*` | The same mesh and clips with M1K3's phosphor treatment (a wireframe over a dark fill) | as above | as above | as above |

The bake (`tools/bake/`, which regenerates everything here): the GLB loaded with three.js in headless Chromium, a 26° camera at a
three-quarter angle, 192 × 96 px with alpha, 16 frames per second of clip
(12 to 48 frames), one PNG per frame. `braille/` holds each frame reduced to
braille cells at the band's size (24 × 6) and a pane's (48 × 12); `svg/` holds
an 80 × 40 strip of at most 24 frames for the desktop surface's SMIL sprite.
`manifest.json` lists the clips, their frame counts and durations.

The app's own pipeline (`macos/tools/companion-pipeline/`) is where the other
companions get baked from; the Quaternius creatures there are CC0.
