# M1K3 — App Store Connect assets

The screenshot system for the iPhone, iPad and Mac listings, built the way
Cartogram's v2 set was built: **real app pixels in `plates/`, the brand layer
rendered over them**, at Apple's exact spec, reproducible from source.

```
marketing/app-store/
├── frames.js        layout + which capture each frame uses  (locale-independent)
├── strings.js       copy per locale (+ Mac overrides)         (a locale = a translation job)
├── config.js        canvas sizes, brand tokens, font paths
├── render.js        HTML/CSS → PNG via headless Chrome (+ .plates.json for the drift check)
├── placeholders.js  labelled stand-in plates until real captures land
├── flatten.py       strips alpha (ASC rejects it, silently in some tools)
├── mask.py          PLATE_MASKS retouches → out/.plates (copies; plates stay as shot)
├── verify.py        spec check: sizes, alpha, count, placeholder plates, plate drift, video, text limits
├── plates.lock.json the plates' hashes at the last by-eye approval (verify.py --approve)
├── contact.py       thumbnail contact sheet — the "does it read cold?" test
├── plates/<ios|ipad|mac>/<name>.png   ← YOUR CAPTURES GO HERE
├── out/<target>/<locale>/NN_id.png    ← rendered set (+ contact-*.png)
└── CAPTURE-PLAN.md  the shot list and how to capture each plate
```

## Run it

Needs Google Chrome (the renderer drives the installed one; no browser download), Node and
`uv` (it supplies Pillow to the Python steps; no venv to make).

```bash
cd marketing/app-store
npm run setup          # fonts + playwright (no browser download; `npm run setup:browser` if no Chrome)
npm run mac            # one command: render en-US → out/contact-mac.png → verify (also ios, ipad)
npm run approve:mac    # ONLY after looking at the contact sheet: stamps plates.lock.json
npm run render         # every target × locale; or: node render.js ios de-DE 03
npm run placeholders   # only writes plates that don't exist yet
```

**Plate drift.** A hand-tuned crop (`focus`, `bands`, `lifts`) is only right for the capture it
was cut on. `render.js` writes `out/<target>/<locale>/.plates.json` (frame → plates read) and
`verify.py` fails every frame whose plate changed since the last `approve`, by name. So a
recapture can never ship an unseen crop (2026-11-24: the 1.6 Settings panes moved under two Mac
crops and the old "spec OK" passed both). Look, fix the crop, then approve.

`macos/tools/screengrab/capture.sh mac|ios` fills `plates/` from the app itself
(CAPTURE-PLAN.md §0b). Or drop a capture in `plates/ios/chat.png` by hand, re-run
`node render.js ios 01`, look at it. Plates are `object-fit: cover`, top-anchored, so any iPhone's screenshot
works — it doesn't have to be a Pro Max. (Portrait frames put the type on top
and the panel below, precisely so the capture never has to be full-canvas.)

## The set (v2, 2026-10-22)

| # | Frame | Layout | Plate(s) | Job |
|---|---|---|---|---|
| 01 | Local AI. Works offline. Stays private. | top | chat | Search words first. Billboard. |
| 02 | Your AI. Your devices. Private by design. | duo | mac + ios/ipad brain-at-home | Mac + iPhone together; the tagline's home. Billboard. |
| 03 | Talk to it. It talks back. | top-pair | voice-listening, voice-speaking | Voice, on-device (English). Billboard. |
| 04 | Pick a brain. Not a plan. | top | onboarding | Free, no account |
| 05 | Ask your PDFs and notes. | top | documents | RAG over your files |
| 06 | It remembers. You can read every memory. | top | memories | Memory you can audit |
| 07 | A companion, if you want one. | top-grid | companion-* | Secondary hook |
| 08 | 0 bytes collected by us. | stat | privacy-label | Trust |
| 09 | Say "please." It takes its turn. | top (+lift) | voice-listening | iPhone/iPad only |
| 10 | One scan. Encrypted. Your Wi-Fi only. | top | brain-at-home | iPhone only (iPad: 9 frames until a scanner/QR capture exists) |

Mac: 01–08 in landscape (duo = laptop + iPhone), plus `06b_constellation` and
`09_you-approve` (Mac only, `targets: ["mac"]`). Ten per target, Apple's limit.
Billboards (01–03) get a 192px h1, a lighter `<dim>` and a 40px eyebrow (`billboard`, `h1px`).

### Why the copy is what it is

- **Apple OCRs screenshot text.** Every headline carries a real keyword from
  `ios-launch/M1K3-iOS-Launch-Package.md` §3 — private, offline, on-device,
  local, voice, notes, PDFs. The frames are a discovery surface, not just conversion.
- **Dry, not snarky.** "0 bytes of your data sent to a server", "Pick a brain.
  Not a plan.", "No account. No cloud. No tracking." The contrast with cloud AI
  does the work; no competitor is named on a store frame (guideline 2.3 and,
  more to the point, taste). Name names in the Reddit / HN posts instead.
- **Nothing invented.** "0 network calls" is the app's own status line;
  Mini/Lil/Big and their taglines are from `BrainTier.swift`; Bonjour / QR /
  TLS from the Brain at Home feature; the 3D companions are the ones vendored on
  the site. If a feature is renamed, rename it here the same day.
- **Frame 08 has a precondition.** "Data Not Collected" must actually be what
  the App Store privacy card says. Set the nutrition label in App Store Connect
  first; if anything is declared, rewrite the sub before shipping.

### Device frames

Every capture sits inside a rendered device — iPhone (titanium rail, Dynamic
Island, side buttons), iPad Pro (thin rail, centre camera) or MacBook Pro (lid,
notch, deck) — with a light 3D perspective, sheen and ground shadow, all CSS in
`render.js` (`.device.*`). For pixel-exact hardware, drop Apple's official
product bezel PNG from developer.apple.com/design/resources into
`bezels/phone.png`, `bezels/pad.png` or `bezels/laptop.png`; `device()` picks it
up automatically and sets `--bezel-inset` for the screen window.

### Brand rules baked in

Canvas `#050505`, monochrome ink, no accent colours — deliberately the opposite
of every purple-gradient AI listing. Titles in VT323 with the phosphor glow — the site's `h1.headline` face
(`M1K3_TITLE=mono` renders the Plex Mono variant for comparison) — the third line in `#8a8a8a` (the "Nothing leaves." move from the
site hero, via `<dim>`). Eyebrows in Plex Mono, tracked uppercase, like the site's `.label`; no mark — the device is the logo. Note the app itself uses Silkscreen as its in-app pixel accent (`PixelFont.swift`); the site and store use VT323. Worth a line in the brand notes so it stays a decision, not drift. The
perspective floor grid from the readme hero sits under everything. Inter for
body only. One idea per frame; the headline does the work.

## Shipping

1. Real plates in, `npm run render`, `npm run verify` — it must print
   `✔ spec OK` three times with no placeholder warnings.
2. Look at `out/contact-*.png` cold. Can a stranger say what the app does from
   frame 1? Are 1–3 the strongest three? Same product across all eight?
3. Copy `out/ios/en-US/*.png` to the iOS fastlane screenshots dir (mirror of
   `macos/fastlane/screenshots_mac/` for the iOS platform), `out/mac/en-US/*.png`
   to `macos/fastlane/screenshots_mac/en-US/`. Then `fastlane <platform> screenshots`
   — this hits live App Store Connect metadata, so it's a deliberate step, never
   part of `render`.
4. iPad: Apple requires a 13" set if the app runs on iPad. Same frames, iPad
   plates. If you'd rather not maintain two sets right now, drop iPad from the
   build target until the iPad shell is worth showing.

## Locales

`LOCALES` in `strings.js` has all twelve store locales (en-US, en-GB, de-DE, es-ES,
es-MX, fr-FR, ja, ko, pt-BR, zh-Hans, ru, ar-SA). The app UI and voice are English-only,
so feature names stay English and every non-English voice frame says the voice is
English — `strings.js` throws at load if one doesn't, and `render.js` throws before
rendering if any frame's copy or `TYPE` is missing (no "undefined" on a frame).

Faces: VT323 titles cover Latin only. ru titles use Plex Mono 700 (Cyrillic faces
are loaded); ja / zh-Hans / ko / ar-SA titles and body use Hiragino Sans / PingFang SC /
Apple SD Gothic Neo / Geeza Pro by `<html lang>`. `TYPE[loc]` scales h1/sub and
line-height; ar-SA sets `dir: "rtl"` on the caption blocks only, and Latin runs in its
strings sit in `<bdi>`. `M1K3_FONTREPORT=fonts.json node render.js` records which
faces each text role actually used, to catch a fallback.

Without Pillow on the system python: `M1K3_PY="uv run --quiet --with pillow python3"`.

## Provenance

Pipeline lifted from `cartogram/CartogramMac/marketing/previews-v2` and the
`app-store-previews` skill on the `marketing/app-store-previews-v2` branch —
same frames/strings/render/verify split, same "real pixels only" rule, re-skinned
for the M1K3 brand. Specs checked against App Store Connect's screenshot
specifications, September 2026.

Signed: Kev + Claude, 2026-09-03

Review: Kev + claude-opus-5.5, 2026-10-22
Screenshots v2: the 10-frame order (duo replaces 06_brain-at-home; 09/10 new for
iPhone/iPad; Mac 06b + 09_you-approve), all 12 locales, Cyrillic/CJK/Arabic faces, RTL,
the duo layout, per-target frame filters, loud copy checks. The duo's Mac plate still has
"Serve my brain" OFF; its screen is cropped to keep the toggle and the MCP picker out.
Confidence: 0.7 — rendered and eyeballed per contact sheet; translations unreviewed by natives.

Review: Kev + claude-opus-5.5, 2026-10-22 (QA round 1)
Fixed the QA blockers/majors in the renderer: crop focus is now aspect-independent (the
laptop constant was wrong, hence the duo's black band) and takes a band [x,y,w,h,fill];
lifts can anchor over their own source; Mac caption lines step clear of lifts; the Life
field keeps out of measured type boxes; top-pair draws scaled devices (clock no longer
sliced); top-grid fills the canvas; eyebrows are capped in JS so iPhone/iPad/Mac keep their
casing; ja/ko subs break by phrase/word. Plates were not recaptured: 08 (web search ON),
Mac 05 (two rows), 10 (paste fallback), the Mac duo toggle OFF are framed around, not fixed.
Confidence: 0.75 — all 36 sets rendered and verified; contact sheets checked by eye on a
sample, not every frame at full size.

Review: Kev + claude-opus-5.5, 2026-10-22 (QA round 2)
New: `focus.bands` (stack bands of a capture at one scale, dropping rows: iPhone/iPad 08's
"Version 1.0.0 (1)", the memory naming a firm, the Speaking card's "I am Mike.", Mac 06's
"cold retard" row), `PLATE_MASKS` + mask.py (retouched copies in out/.plates: the Mac's
v1.0.0 badges and OFF switch, the ghost "I kno…" marquee, fox mesh in onboarding gaps and
beside the Mac card), `tileFocus` (07 tiles clear the status bar), `pairFocus`/`pairNudge`,
anchor `img` index, lifts keep a bottom margin, "Mac" caps in prose. Mac 01/04/05/06 lifts
anchored over their sources; Mac 08 is header + Spotlight (no Private Cloud Compute);
the duo screens show the window header and tabs. iPad drops 10. Copy: pt-BR 09 says
"inglês", ar-SA/zh-Hans/en Mac subs wrap by phrase.
Confidence: 0.75 — 36 sets re-rendered, verified, contact sheets opened for 11 of them.
Open: recapture the Mac brain-at-home (toggle ON, paired device), documents with a grounded
answer (05, every target), the iPad/iPhone Speaking plate on a line without "Mike", and the
privacy-label plates on 1.2.1 with web search OFF; each retires a mask or band above.

Review: Kev + claude-opus-5.5, 2026-10-22 (iPhone/iPad recapture, 1.2.1)
Every iPhone/iPad lift, mask, band and tile focus was measured again on the new plates
(frames.js). Retired: the Speaking "Mike" bands (03, both targets), the iPhone memories band
(06; no firm in the new list), and the old gap masks, which had been painting black stripes
across the Lil card. Kept, re-measured: the onboarding gap masks (the fox still shows between
the four cards) and an iPad 06 band that drops "Niamh Cullen…", a person's full name. New:
bands on 09 that take out empty black, so the "please" hint shows above the fold. verify.py
no longer flags a real plate that is a thin wireframe on black (the iPad fox) as a placeholder.
Confidence: 0.75. 24 sets rendered and verified; contact sheets read for en-US, ar-SA, ja and
ru, plus frames 01-04 and 09 at full size.
Open: the iPad onboarding plate shows Private Cloud Compute "unavailable" (Simulator), with
lattice through its dimmed card, under a sub that names Apple's private cloud. Recapture it on
an iPad with Apple Intelligence, or give iPad its own frame-04 sub. brain-at-home and
privacy-label (02/08/10) are still the September plates (14:08 clock).

Review: Kev + claude-opus-5.5, 2026-10-22 (QA round 1 on the 1.2.1 plates)
iPad 04 drops the PCC card (screen band + lift end at Home) and its sub says the private cloud
is there "where available" (strings.js IPAD_04_SUB, 12 locales); the screen starts below the
status bar, so the lift sits over its source unclamped (no doubled card). Card-corner lattice
goes via mask.py `keep` (rounded cards are never painted). iPad 03 bands both voice plates: the
reply card shows on the front device, the back shows fox + pill + mic (no transcript under the
bezel). 09 lifts only the "please" pill, `bare` (no box round the pill), on both targets.
iPhone 05 lifts the list; iPad 05 lifts toolbar + title + whole card. iPad 06 drops row 4 so the
lift's edge lands in padding. 07 crops each creature on its own (`tilePlateFocus`), band fade on
iPhone. Old plates (02/08/10) have the status bar banded out and the Settings nav ghosts
painted to the bar's grey. iPhone 03: the grey "N" face between the fox's legs keyed out
(`key: "bright"`). RTL: device tags stay left, the 2×2 grid reads from the right. de-DE tags.
Confidence: 0.75 — 24 sets rendered and verified; contact sheets read for en-US, de-DE, ja,
ar-SA (both targets), full-size crops of every changed frame in en-US.
Open: recapture documents with a PDF and a grounded answer (05 is still a two-row list over
black), voice-listening with a short utterance ending in "please" (the transcript is truncated
by the app), brain-at-home and privacy-label on 1.2.1 at 09:41 (retires the status bands and nav
masks), iPad onboarding where PCC is available, and chat with the fox clear of the action row.

Review: Kev + claude-opus-5.5, 2026-10-22 (QA round 2 on the 1.2.1 plates)
iPhone 03: `pairFocus.ios` drops the back screen's transcript and "please" pill (they ran under
the front bezel mid-word); fox, then mic. The pair spreads 25u/20u so the tail clears the bezel.
08: the nav-bar ghosts are now each column's own clean tone (mask.py `fill: "col"`, ramped up
from black), not a flat slab with hard edges; iPad's flat fill no longer smears the blue glow.
05/10 iPhone lifts are the card alone, `bare` with the card's own 80 px corner (no box in a
box). 06 iPhone ends on row 6's separator and empty card padding, not mid-row. iPad: mask.py
`key: "solid"` (a 7 px opening, 2 px rim) removes the fox's grey leg faces on the Speaking,
Listening, chat and Fox-tile plates and keeps the lattice. iPad 04 shows the PCC card as shot
("unavailable") under the lifted three, then "Private by design", and the band ends above the
resize grip; the iPhone 04 sub now carries the same "where available" hedge (IPAD_04_SUB).
iPad 03 tags sit in black above each fox (front device 160u higher, Interrupt out); 06 row 5
clear of the lift's shadow; 07 Inkfish window ends above "Listening…"; 09 pill 14u down; 01
lift drops the toolbar band and starts at the question; 02 grip painted out.
Confidence: 0.75 — 24 sets re-rendered and verified; contact sheets read; changed frames
checked at full size in en-US and spot-checked per locale.
Open: 08's corner "No data centers were harmed." beside 04's PCC card is Kev's call (brand
line). Still owed captures: documents with a PDF and a grounded answer (05), chat with the fox
clear of the action row (01), voice-listening with a short "please" line (09 truncation), the
iPad Speaking plate on a plain answer (03), brain-at-home and privacy-label on 1.2.1, and an
iPad onboarding plate with PCC available.

Review: Kev + claude-opus-5.5, 2026-10-23 (QA round 5: brain-at-home + privacy-label on 1.2.1)
New plates: iPhone/iPad brain-at-home ("Pair with your Mac", 09:41) and privacy-label (Settings at
Content Controls + Grounding; the iPad's also shows Answer ratings). Retired with the September
plates: `BAH_NO_STATUS`, both nav-bar `privacy-label` masks and the iPad brain-at-home grip mask.
02: the screen is the sheet's rows (`BAH_SHEET`). The sheet is the top ~51% of the iPhone plate
and ~28% of the iPad's, so DUO_PORTRAIT draws the device larger (800/900u) running off the
canvas's right and bottom edges, the `top` layout's bleed: the visible device is the sheet, text
whole. 08: the screen is Content Controls + Grounding on black (status and nav bars, Voice,
Appearance and Reading out); iPad adds the Answer ratings header and its "They stay on this
device" footer (the card's rows dropped to fit), with the resize grip masked black. 10: the
"No camera? Paste the link" section is banded out, "Codes expire…" follows the lifted card.
04 iPad: the band ends at the Home card (PCC "unavailable" and the lock line out) and
`IPAD_04_SUB` names only the device and the Mac over your own Wi-Fi (12 locales); the hedged
"where available" line is now `PHONE_04_SUB`, the iPhone's alone.
Fox legs (QA claim on the iPhone chat / Listening / Speaking / Fox plates), measured in the leg
rows: lattice lines are mid-grey (median 171-178, nothing above 200), so the grey/white split
doesn't separate them; a 7 px morphological opening does. chat, Listening and the Fox tile have
0.4-0.5% solid pixels in the region (largest patch 13×23 px, an edge-on sliver): black faces under
the lattice, the claim isn't borne out. Speaking has one solid 39×58 px face (the QA r3 "N",
already keyed by the existing mask); the iPad reference plates QA r4 flagged run 6.4%.
Confidence: 0.75 — 24 sets rendered and verified; contact sheets read for ios-en-US, ipad-en-US,
ios-ar-SA and ipad-ja; 02 (both targets), iPad 04 and iPad 08 montaged across all 12 locales, and
the changed frames checked at full size in en-US (02 also in ja and ar-SA).
Open: 08 shows "Web search in chat" ON with a footer naming DuckDuckGo and Apple's PCC under
"Nothing phones home." (honest, but Kev's call; a capture with it OFF reads cleaner). The Mac duo
draws plates/ios/brain-at-home whole: the new plate changes it on the next Mac render, which this
round did not run. The Speaking "N" face is an app render defect worth a look in the fox mesh.
iPad 04 translations unreviewed by natives.

Review: Kev + claude-opus-5.5, 2026-10-23 (QA round 6: 05 is a grounded chat turn)
iPhone/iPad 05 now use `ask-documents` (1.2.1 + #670, Mini answering "what do my lair notes say
about the roofline?" from the seeded notes, with the "Lair — planning notes" source chip and "Used
knowledge search"); documents.png stays on disk for the Mac 05 frame, which is unchanged. The lift
is the whole turn, question to "Used knowledge search", ~1.3× its source and anchored over it; the
answer is whole and unedited. The toolbar rows are banded out so the lift's top edge meets black,
not half-icons. New mask.py key `neutral`: on the iPhone plate the fox lattice (neutral grey) behind
the action row and chip goes black, while the chip text and icons (tinted, b - r 2-6) stay; the
answer bubble's rows are outside the mask. Every locale's 05 sub ("answers from your own files,
searched on the device") matches the turn.
Confidence: 0.8 — 24 sets rendered and verified; 05 read at full size on both targets and in the
ios-en-US, ipad-en-US and ios-ar-SA contact sheets.
Open: the iPhone answer names "Architect Niamh Cullen", the seeded full name that 06 bands out on
iPad. It can't be cut without editing the answer, so it's Kev's call: keep it, or recapture with
notes that use a role instead of a name. The iPhone and iPad turns are different runs (the iPad
answer is one line: "The original roofline is kept.").

Review: Kev + claude-opus-5.5, 2026-11-25 (lean pipeline; tracked in the repo)
Kev: "get lean, and optimal and keep refining the design and bugs". The code is tracked now (plates,
out/ and node_modules stay ignored). The renderer drives the installed Chrome (the bundled
chromium-1148 hung four hours unpacking; Chrome renders the Mac set in about 14 s). uv supplies
Pillow. `npm run <target>` is the whole pass, and verify.py's plate-drift check fails any frame
whose plate changed since the last by-eye `approve`. Mac 1.6 set: no lifts (Kev, 11-24); 04 on the
brain-picker plate; 08 re-cut for the Settings panes; 09 on the new agent-scripts plate (the pane
scrolls itself under the harness, and capture runs pin dark). Confidence 0.8: the drift check is
unit-tested, and the rest was run once end to end.
