# M1K3 launch site

The M1K3 site: the launch page, the install and developer pages (`/install`, `/agents`,
`/local-api`), the guides, and the legal pages, for Mac, iPhone and iPad. Self-contained: THREE.js is vendored
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

Phosphor Fox is the same Fox mesh under M1K3's phosphor shader — same credit.

The other companions — Gecko, Inkfish, Colobus, Sparrow — are by Quaternius (CC0,
public domain; no attribution legally required, credited as courtesy).
https://quaternius.com. The canonical list with licences is the repo NOTICE and
`macos/Sources/M1K3Avatar/Companions/ATTRIBUTION.md` (ships inside the app bundle).

## One source for shared parts

- **Footer:** every page's `<footer>` is written by `macos/tools/site/footer.py` (grouped
  columns). Edit the columns there and run it; `--check` and `test_footer.py` fail on a
  hand edit. `brains.html` is generated and asks the same function.
- **`llms-full.txt`:** generated from the pages by `macos/tools/site/llms_full.py`
  (CI runs `--check`). Regenerate after any page edit. `llms.txt` is hand-written.
- **Tests:** `python3 -m pytest macos/tools/site` pins the structured data, the privacy
  crossings, the store links, the tagline and the footer.

The hero fox does its trick on a click. The on-screen hint and the double-click
companion swap were removed on 2026-11-16 (Kev: "it's noisy").

_Signed (this section and the launch-pass edits only): Kev + claude-fable-5.2, 2026-11-16, Confidence 0.8. Prior: Unknown. Launch pass: grouped footer from one source,
the `/local-api` page, and a claims pass against the repo (tool count, model names, test
count, platforms, and the storage wording: only saved call records are encrypted)._
