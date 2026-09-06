# M1K3 launch site

Single-page launch site for M1K3 for Mac. Self-contained: THREE.js is vendored
in `vendor/` (originally from the attic's web-avatar node_modules — history
before `7545b4a4`), the hero fox is a local GLB —
no CDN required for the 3D, and fonts are self-hosted in `fonts/` (`fonts.css`) —
zero external requests, fitting for a "no cloud attached" product. VT323 is
preloaded so the headline never paints in the fallback mono (which is how the
first `og.png` ended up in the wrong face).

## Run

```bash
make site        # from repo root — serves + opens http://localhost:8002
# or: cd site && python3 -m http.server 8002
```

**Don't open index.html by double-clicking it.** Chrome blocks ES modules and
fetch over `file://` (unique-origin policy), so the 3D won't load. It must be
served over http. If the GLB still can't load, the hero falls back to a
procedural wireframe icosahedron.

## Hero

`vendor/Fox.glb` with a phosphor treatment (dark body + additive wireframe
shell). Idles on the `Survey` clip, takes a short `Walk` every ~11s, and `Run`s
when clicked. Camera has mouse parallax + scroll drift.

Attribution: the Fox is the glTF sample asset — model by PixelMannen (CC0),
rigging/animation by tomkranis (CC-BY 4.0). Credited in the site footer.
https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/Fox

The other companions — Gecko, Inkfish, Colobus — are by Quaternius (CC0, public
domain; no attribution legally required, credited as courtesy). https://quaternius.com
