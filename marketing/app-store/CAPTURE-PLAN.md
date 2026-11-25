# M1K3 — capture plan: screenshots + App Preview demos

What to put in front of the camera, in what order, so the frame system in this
folder renders a shippable set in one pass. Written to the same rules as the
Cartogram Mac set (`cartogram/.claude/skills/mac-screenshots`): real pixels,
nothing personal on screen, a safety check before anything leaves the machine.

Budget: **one evening for the iPhone plates, one for Mac, a third for the two
preview videos.** Don't try to do all three in one sitting — the second pass is
where these get good, and you can't do a second pass tired.

---

## 0. Before you capture anything — stage a demo persona (30 min)

Every plate is a screenshot of the app's *state*. The state has to be worth
looking at and contain nothing of yours. Do this once, on a fresh install
(delete the app → reinstall from TestFlight), and reuse it across every device.

**Demo corpus** — drop these in `marketing/app-store/demo-corpus/` and import
them on each device (AirDrop → Documents):

| File | What it's for | Why this |
|---|---|---|
| `retrofit-planning-notes.pdf` | Frame 04 (documents) + the hero chat answer | The site's own demo line is *"summarise yesterday's call with the architect"* — keep the whole listing telling that one story. Fictional house, fictional architect. |
| `bread-formula.md` | A second, obviously-different document | Shows range. Harmless, nobody's data. |
| `a-short-paper.pdf` | Anything CC-licensed, ~10 pages | Proves PDFs, not just notes |

**Demo memories** — talk to it for ten minutes so `Memories` fills with dated,
believable, *invented* facts: the planning deadline, the architect's name
(fictional), a preference or two. Nothing about Ardmore, Round Tower clients,
or anyone real.

**Demo conversation for the hero** — one exchange that a stranger reads in
three seconds and gets:

> **you:** summarise yesterday's call with the architect
> **M1K3:** You agreed the retrofit keeps the original roofline; planning docs are due Friday. Want the action list?

> **2026-09-08 — the villain cut (Kev).** The plates now open on *first contact* — **you:** who are you, and who else is listening? / **M1K3:** I am M1K3. I live on this Mac and answer to you alone. Nobody else is listening. I checked. Twice. — the memories are in M1K3's own voice (tea over coffee, "the lair", no phone to phone home with, the loaf, recursive self-improvement: none so far), the voice plates dictate "introduce yourself…", and Lil fronts every plate. `DemoPersona.swift` is the source; the site's terminal demo still tells the plainer architect line above.

That's lifted from the site's terminal demo, so the site, the README hero and
the store listing all say the same thing.

**Device hygiene** — Airplane Mode ON (the icon in the status bar is the best
proof line the listing has, keep it), Do Not Disturb, 100% battery, no
notification badges, Wi-Fi off, Bluetooth off. Wipe any real chat history
first.

---

## 0b. The automated way — the screengrab suite (2026-09-07)

Everything in §0–§2 is now a test suite: one XCUITest per plate, on both
shells, driven by `macos/tools/screengrab/capture.sh` (in the repo; this
`marketing/` folder is local-only). It launches the app with
`M1K3_SCREENGRAB=1`, which does three things and nothing else:

- **Isolated store root.** Every store (knowledge, memory, chat history) opens
  under `Application Support/M1K3-screengrab/` beside the live `M1K3/`. Your
  own memories, documents and conversations never enter a frame, and the live
  root is never read or written. Delete that sibling folder to start over.
- **Demo persona seeded** on launch (`macos/Sources/M1K3Screengrab/DemoPersona.swift`
  — the §0 story: the retrofit, Niamh Cullen, the Friday deadline, the weekend
  loaf). A test pins that nothing real is in it.
- **Read-only overrides** for first-run state and the face through launch
  arguments (`-hasChosenBrain NO`, `-voiceMode.companion Fox`): Foundation's
  argument domain shadows persisted defaults and persists nothing.

```bash
# Mac — quit the live M1K3 app first (same bundle id). Window-only captures at
# 1440×900 pt land in plates/mac/, then verify.py runs.
macos/tools/screengrab/capture.sh mac                 # all twelve
macos/tools/screengrab/capture.sh mac chat memories   # a subset

# iPhone / iPad — a PHYSICAL device (the brains need the GPU).
macos/tools/screengrab/capture.sh ios <device-udid>
# 2026-09-09: 12/12 shot on the iPhone 17 Pro (udid 00008150-00195CAA1E8B401C,
# wired) in ~150 s warm. If the first xcodebuild says "Timed out waiting for all
# destinations", run `xcodebuild -showdestinations -scheme M1K3iOS` once and retry.
```

Then `node render.js <target>` + the contact sheet as below. Still by hand:
`privacy-label` from the live listing once it exists (the suite captures the
Settings stand-in), device hygiene for the iOS lane (Airplane Mode on, DND,
full battery — the status bar is real pixels), and the §3 videos.

## 1. iPhone plates — 12 captures, one device (evening 1)

**Device:** a physical iPhone, not the Simulator — the MLX brains need the real
GPU and the Simulator can't show the app doing its actual job. Any 6.9" phone
(15 Pro Max upward) gives native 1320×2868 / 1290×2796; a smaller phone is
fine too — the portrait frames inset the capture, so it never has to be full
canvas. Side button + volume up, then AirDrop the batch to the Mac and rename
into `plates/ios/`.

Work in this order — it's the order the app naturally goes through, so state
carries forward:

| # | Plate file | Capture this | Watch for |
|---|---|---|---|
| 1 | `onboarding.png` | Fresh-install *"Pick a brain."* with the lock line and the three tiers | Do this **before** anything else — it only exists once per install |
| 2 | `chat.png` | The hero exchange above, answer fully rendered, status line showing the brain and `0 network calls` if the shell prints it | Airplane icon visible; no keyboard up unless the composer looks good with it |
| 3 | `voice-listening.png` | Voice mode mid-listen — waveform / avatar reacting | Say a full sentence so the transcript has real words |
| 4 | `voice-speaking.png` | Voice mode mid-reply — karaoke captions with a highlighted word | Screenshot on the second sentence, not the first (first is often still loading) |
| 5 | `documents.png` | Documents screen with the three demo files imported, indexed state | If there's a "grounded in…" citation UI, show it |
| 6 | `memories.png` | Memories screen, 4–6 dated entries | No real names, no real places |
| 7 | `brain-at-home.png` | The pairing sheet with a QR, or the "connected to <Mac name>" state | Rename the Mac to something like `Studio` first — hostname is personal data |
| 8–11 | `companion-fox.png` `companion-gecko.png` `companion-inkfish.png` `companion-colobus.png` | The avatar surface with each companion, same framing, same idle pose if possible | These become 2×2 tiles cropped to centre — keep the creature centred |
| 12 | `privacy-label.png` | The App Store privacy card ("Data Not Collected") — from the live listing once it's up, or the App Store Connect preview | Until the listing is live, capture Settings → Privacy as a stand-in and swap later |

Then on the Mac:

```bash
cd marketing/app-store
npm run ios    # render → contact sheet → verify; look, then npm run approve:ios
open out/contact-ios.png
```

Look at the contact sheet cold. Frame 1 should be readable from across the room.

**iPad (optional, same evening if you have one):** identical list into
`plates/ipad/`. Apple requires a 13" set only if the app runs on iPad; if the
iPad shell isn't ready for its close-up, leave the target out of the build for
this submission.

---

## 2. Mac plates — 12 captures, window-only (evening 2)

Capture **the window, not the screen**. That sidesteps the whole desktop-clutter
problem that bit the first Cartogram set (folder names, Dock, a live 2FA code),
and the frame system does the rest.

Set the M1K3 window to exactly **1440×900 points** (2880×1800 px on Retina —
native to the `edge` layout, no scaling). Then:

```bash
# click the M1K3 window when the crosshair appears; -o drops the shadow, -x the sound
screencapture -o -x -W ~/Desktop/plate.png
```

Same twelve subjects as iPhone, into `plates/mac/`. Differences:

- `chat.png` is full-bleed in the hero (`edge` layout, type bottom-left over a
  scrim) — keep the interesting content in the **upper two-thirds** of the
  window; the bottom-left gets darkened for the type.
- `onboarding.png`, `documents.png`, `brain-at-home.png` are shown zoomed
  (`split` layout, 1.3×, anchored top-left or centre) — the left third of the
  window is what people will see. Compose for that.
- `voice-speaking.png` is full-bleed — a big avatar with karaoke captions is the
  ideal.

```bash
npm run mac    # render → contact sheet → verify; look, then npm run approve:mac
```

---

## 3. App Preview videos — one per platform (evening 3)

Apple allows up to three per locale; one good one beats three average ones.
15–30 s, **must carry an audio track even if silent** (verify.py checks).

### iPhone preview — "Airplane mode, then ask." (~22 s)

Record on the device with Control Centre → Screen Recording (mic off), then
trim. Beats:

| t | Beat |
|---|---|
| 0–3 s | Control Centre: tap Airplane Mode on. Close it. (The whole pitch, wordlessly.) |
| 3–10 s | Chat: type the architect question, answer streams in |
| 10–18 s | Tap the waveform, ask a follow-up out loud, it answers in voice with karaoke captions |
| 18–22 s | Swipe to Memories — the new fact is already there. Hold. |

Spec: portrait **886×1920** (Apple's 6.9" preview size), H.264, 30 fps, silent AAC:

```bash
ffmpeg -y -i raw.mov -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
  -filter:v "scale=886:1920:force_original_aspect_ratio=increase,crop=886:1920,fps=30" \
  -c:v h264 -pix_fmt yuv420p -profile:v high -b:v 8M -c:a aac -shortest preview_iphone.mov
./verify.py --video preview_iphone.mov --target ios
```

### Mac preview — "Pull the cable." (~20 s)

This is the only step that records the **whole physical screen**, so the
Cartogram safety protocol applies in full:

1. Hide everything: ⌘⌥H in M1K3, `defaults write com.apple.finder CreateDesktop false; killall Finder`.
2. **Take a static screenshot and look at it** before recording. "Frontmost app is M1K3" is not the same as "nothing else is visible."
3. Record: `screencapture -v -V20 raw.mov` — with nobody else's window, notification or 2FA code anywhere on the display.
4. Extract and *look at* start / middle / end frames before keeping it. Anything personal → delete raw + frames, don't retry solo.
5. Restore: `defaults write com.apple.finder CreateDesktop true; killall Finder`.

Beats: menu bar Wi-Fi toggled off (0–3 s) → chat question + streamed answer (3–10 s) →
voice reply with the avatar (10–16 s) → Memories / knowledge graph search (16–20 s).

Crop to 16:10 and encode (adjust the crop for your display; the 16" is 3456×2234 with a ~37 px menu bar):

```bash
ffmpeg -y -i raw.mov -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
  -filter:v "crop=3456:2160:0:37,scale=2880:1800,fps=30" \
  -c:v h264 -pix_fmt yuv420p -profile:v high -b:v 12M -c:a aac -shortest preview_mac.mov
./verify.py --video preview_mac.mov --target mac
```

Note from Cartogram: fastlane's built-in `app_previews_path` silently skips Mac
previews (no `DESKTOP` entry in its resolution validator, verified against
2.236.1). Reuse the custom `:previews` lane from `CartogramMac/fastlane/Fastfile`.

---

## 4. Off-store cuts (same footage, no new shoot)

Once the two previews exist, the Cartogram social README already documents
the ffmpeg reframes (blurred-pillar vertical for Reels, 16:9 for X). Cut the
same three formats from the iPhone preview and label the folder
`marketing/social-2026-09/` — and this time keep the command line beside the
renders. The Reddit post (`marketing/09-soft-echo-drafts.md`, r/macapps) is where
the craic goes: that's the place to say what the cloud apps *can't* do, by name.

---

## 5. Definition of done

- [ ] `npm run verify` prints `✔ spec OK` for ios and mac (and ipad if shipping) with **no** placeholder warnings
- [ ] Contact sheets reviewed cold; frames 1–3 are the strongest three
- [ ] Privacy label in App Store Connect actually reads "Data Not Collected" (frame 08 depends on it)
- [ ] Both previews pass `verify.py --video`
- [ ] Every plate audited for personal data — hostnames, real names, real places, real documents
- [ ] Plates + rendered set committed together (a shot that only exists as a file isn't reproducible — the lesson from Cartogram's 05–08)
