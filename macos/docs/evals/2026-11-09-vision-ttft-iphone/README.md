# Seeing on the iPhone — time to first text, 2026-11-09 (#768)

**Verdict: GO for ambient eyes and for Mini on a streamed turn (0.7–1.0 s warm; the first call after
launch took 1.0–2.3 s). NO-GO for Lil the way the app sends a photo today (9 s to first text). Lil's
floor is promising, not proven: 0.65 s of prefill and a whole sentence in 2.0–2.5 s on a bare caption,
with first text unmeasured. Lil's go waits on a lean "look" route, measured the same way.**

The bar on #768: "time to first token for one ~1024 px frame plus a short question, through Mini (iOS 27
image `Attachment`) and through Lil. Go if it's under about 2 s." This record closes that item and the
ambient pass's cost per frame. The 10-minute heat and battery session is still owed.

## Method

- Device: iPhone 17 Pro (iPhone18,1, 12 GB; the harness reads 11), iOS 27.2 (24B119), wired to the Mac.
  Thermal state `nominal` on all 30 result lines.
- Build: Release `M1K3iOS` off master `3a562541` plus a harness that never ships: `M1K3iOSApp/VisionSpike.swift`,
  inert without `M1K3_VISION_SPIKE=1` in the launch environment, driven by `tools/dev/vision-spike.zsh`.
  Both live on the branch `eng/vision-spike-768`, which is local and not pushed.
- One still photo, not a live camera frame: "Fades and Blades, 130 Thomas Street, Dublin" from Wikimedia
  Commons (CC0, by Ridiculopathy, a Samsung SM-A405FN phone photo of 2024-07-15),
  <https://upload.wikimedia.org/wikipedia/commons/1/19/Fades_and_Blades._130_Thomas_Street%2C_Dublin%2C_Ireland._The_oldest_house_in_Dublin.jpg>.
  The harness scales it once to 576×1024 (a 175 KB JPEG) before any timer starts, so camera capture and
  scaling are outside every number here. What is in it: a grey three-storey building, the shop sign
  "Fades & Blades — Traditional Barber's Parlour", an Irish flag in the window, a barber pole, a woman on
  the pavement.
- Question: "What is in this picture? One sentence."
- Five arms, three runs each, the first of each arm cold. The whole set ran in two launches, A and B:
  - `ambient`: no brain. Vision text recognition (fast and accurate) and `VNClassifyImageRequest` on the photo.
  - `mini`: the app's own send on Mini: grounding gate, agent loop with eight tools, 3,054 chars of
    grounding. The answer arrives nearly whole: the turn ended 46–306 ms after first text.
  - `mini-stream`: a bare `LanguageModelSession.streamResponse` with the same `Attachment`. Mini's floor.
  - `lil`: the app's own send on Lil (Qwen3.5-4B-MLX-4bit): persona, tools, thinking policy. The
    production number.
  - `lil-floor`: `MLXBrainProvider.caption`: thinking off, neutral instructions, not streamed, so it has
    a total and a prefill (the `ttft caption` line), not a first-text reading.
- `first_text_ms` is a 4 ms poll of the transcript. It read 19–73 ms after the app's own
  `turn first chunk` line on all twelve app turns.
- Launch A had a confound of the harness's own: each app turn opens a new conversation, which starts the
  previous conversation's memory distiller and a title (in launch A, a 1.9k-token generate on Lil beside
  the Lil turn being timed). Launch B waits 15 s after opening the conversation (`settle_s=15`).
  **Read launch B for the app arms.**

## First text, ms (cold / second / third run of the arm)

| arm | launch A, unsettled | launch B, settled 15 s | against about 2 s |
|---|---|---|---|
| ambient: text, fast | 108 / 9 / 9 | 108 / 7 / 7 | far inside |
| ambient: text, accurate | 143 / 56 / 59 | 134 / 46 / 47 | far inside |
| ambient: scene labels | 39 / 9 / 8 | 38 / 7 / 7 | far inside |
| mini-stream | 2,254 / 980 / 882 | 1,040 / 730 / 781 | inside when warm |
| mini (app send) | 3,733 / 1,738 / 3,687 | 2,371 / 1,903 / 2,002 | on the line |
| lil (app send) | 17,066 / 9,648 / 13,983 | 13,806 / 8,952 / 9,221 | 4.5× over when warm |
| lil-floor, total for the whole sentence | 5,154 / 2,413 / 2,063 | 4,038 / 2,030 / 2,463 | not a first-text number |
| lil-floor, prefill | 1,845 / 683 / 653 | 1,148 / 651 / 651 | a prefill, not first text |

Totals for the app sends: Mini 2.1–2.7 s settled; Lil 10.4–17.5 s settled.

## Why Lil's app turn takes 9 s

An image turn throws the cached prompt away. Every Lil app turn in both launches logged
`toolTurnSession reuse: 0/4087 tok from cache, prefilling 4087, seed=persona` (4,175 on the last two) and
then a prefill of 8.3–9.1 s settled, 9.3–13.0 s unsettled. That is the whole wait: on the two settled warm
turns the first chunk was logged within 65 ms of the prefill figure, and by the log's own timestamps
10–20 ms after the prefill ended (the rest is the render before the send).

The code says so itself, `Sources/M1K3MLX/MLXToolCalling.swift:1100`: "An image anywhere in the render
vetoes the suffix fast path … The full prepared input prefills on a fresh cache instead — correct, just
re-prefills the persona", with the same `turnCarriesImages` guard in `CrossTurnCacheReuse.suffixReuseAllowed`
and `ExactPrefixReuse.plan`. It is marked an optimisation follow-up, not a correctness issue.

Three more readings from the same log:

- The cold turn pays twice. The first Lil turn after launch spent 5.2–5.3 s before
  `persona prefix built: 2753tok`, then prefilled all 4,087 tokens without using that prefix.
- Launch A's contention added 0.7–4.8 s to a warm turn (9.6 and 14.0 s against 9.0 and 9.2 s). It was
  never the cause.
- Lil prefills about 460–490 tokens a second on this phone, settled. Reusing the 2,753-token persona
  would still leave about 1,330 tokens of grounding, image and question. A straight-line estimate from
  that rate puts a veto-free turn near 2.7–2.9 s. It is an estimate, not a measurement: it ignores what
  restoring the cache costs and how image tokens prefill. The floor arm is the measured one: a 183-token
  prompt, 0.65 s of prefill, the sentence done in 2.0–2.5 s.

Not measured here, read from the code only:

- A second turn in a conversation that already holds a photo. The guard is true for any send whose
  transcript still carries an image, so such a turn re-prefills in full for as long as the photo stays in
  the transcript.
- A photo turn that calls a tool. The same comment says the image re-encodes on every iteration, so the
  full prefill is paid again after the tool returns.

## What the answers were like (six per arm, one photo: a smell, not a score)

The result lines cut each answer at 160 characters, so these counts read the first 160 only.

- **lil (app send):** 6 of 6 said "traditional barber's parlour" and saw the Irish flag. The only arm to
  name the business right every time.
- **lil-floor:** the same model on the neutral caption prompt named the business rightly in 3 of 6
  ("hair salon" twice, "haircuts and hairdressing" once) and wrongly in 2 ("vintage clothing store",
  "Irish pub"), and called the three-storey building "two-story" in 4 of 6. A lean route has a quality
  cost to check, not only a speed gain.
- **mini (app send):** the sign read right 6 of 6, none said what the shop is. In launch A, 2 of 3 answers
  carried junk: a trailing "[Image description based on visual evidence]." and a run of raw coordinates.
  In launch B, 3 of 3 were clean.
- **mini-stream:** the sign read right 5 of 6 ("Faces & Blades" once); short and clean.
- **ambient:** the labels were generic (structure, conveyance, portal, window, outdoor: nothing says
  "shop"). The text pass found four lines at this size, with the sign as "FadeS & Blades" and the small
  plate garbled. On this photo the useful part of an ambient line is the text, not the labels.

## Memory, heat, battery

MLX memory across the fifteen `mlx-memory` lines of each launch, in MB: active 3,050–3,902, peak
3,457–4,517, app footprint 3,609–4,499, on a 12 GB phone. Lil's 8 GB floor with a photo in the prompt is
unmeasured. Thermal stayed nominal and the battery read 60, then 55 near the end of launch B. Two runs of
about 1.3 and 2.5 minutes say nothing about a ten-minute session with the camera and speech recognition on.

## What the harness left on the phone

The app arms are real turns: 12 one-turn test conversations sit in the phone's chat history (the drill
deletes nothing). The distiller read them, dropped what it could not anchor, and after the first settled
Lil turn wrote one fact: "The user wants a one-sentence answer when asked about specific images or
scenes." That fact rode in the next two Lil turns' grounding (3,053 → 3,450 chars, 4,087 → 4,175 tokens).
A rerun should keep the app arm away from the distiller.

## What this says to build

1. Ambient eyes are cheap on a pre-scaled still: the three passes back to back took 60–76 ms warm, the
   accurate text pass alone 46–59 ms, against a 2 s tick. Recheck on live frames, where nothing is cached.
2. Mini's look turn should stream. The bare streamed call is 0.7–1.0 s warm; the app's send sits on the
   2 s line.
3. Lil needs a look route of its own before it is in the loop: short instructions, no tool palette, no
   grounding block, streamed. Lifting the image veto should help every photo turn in chat, but by the
   estimate above it would not be enough by itself for a spoken loop.

## Files

`launch-a-unsettled.txt`, `launch-b-settled.txt` the harness's result lines as written on the phone
(answers cut at 160 chars) · `timing-log.txt` the `ttft`, cache-reuse, first-chunk, `mlx-memory`,
`afm turn` and distiller lines from both console streams, in order.

Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.8 — one still photo, one question, three runs an
arm, one 12 GB phone. The Lil verdict is not close (4.5× over) and its cause is read from both the log and
the source. The Mini app send is close enough to the line that another photo could move it either way.
Open: the heat and battery session; a real camera frame; a second turn in a photo conversation; Lil's
lean route with a streamed first-text number.
