# Seeing on the iPhone — time to first text, 2026-11-09 (#768)

**Verdict: GO for ambient eyes, for Mini on a streamed turn (0.5–1.0 s warm; the first call after launch
took 1.0–2.3 s) and for Lil on a lean "look" route (0.56–0.91 s to first text, the sentence done in
1.3–3.2 s; launch C below). NO-GO for Lil the way the app sends a photo today (9 s to first text), and
the app's send is not the route for a spoken loop on either brain: Mini sits on the 2 s line, and a
follow-up about the photo went to web search on both.**

The bar on #768: "time to first token for one ~1024 px frame plus a short question, through Mini (iOS 27
image `Attachment`) and through Lil. Go if it's under about 2 s." This record closes that item and the
ambient pass's cost per frame. The 10-minute heat and battery session is still owed.

The record has two parts. Launches A and B (the first sections) timed the app's send against each brain's
floor. Launch C, later the same evening, timed the lean route those launches pointed at, and a second and
third turn in a conversation that holds the photo.

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

Totals for the app sends: Mini 2.1–2.7 s settled; Lil 10.4–17.5 s settled. The `lil-floor, prefill` row
is not in the result files: it is the `prefill=` figure on the six `ttft caption` lines of each launch in
`timing-log.txt`.

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

Not measured in launches A and B, read from the code only:

- A second turn in a conversation that already holds a photo. The guard is true for any send whose
  transcript still carries an image, so the reading was that such a turn re-prefills in full for as long
  as the photo stays in the transcript. **Launch C measured it and the reading was wrong for the turns it
  sent:** the router took both follow-ups off the tool route, and neither re-prefilled the photo turn
  (see "The second arm").
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

## Launch C: the lean look route, and a second turn

Same phone, same photo, same build plus two harness arms (`arms=look,second`, `settle_s=15`). About 3.3
minutes from start to done, thermal `nominal` on all 42 result lines, battery 55 → 50.

### The look arm

The frame goes straight to the brain with short instructions: no persona, no tool palette, no grounding
block, no chat history, streamed. Mini is the same bare `LanguageModelSession.streamResponse` as
`mini-stream`. Lil is the caption seam (`MLXBrainProvider.caption`, thinking off), now with a first-text
reading: a probe marks the first visible piece of the stream, which launches A and B did not have.

Four prompts at 576×1024, then the plain one at two smaller sizes:

- `look`: instructions "You describe what a photo shows, briefly and exactly.", then the question.
- `look-read`: instructions "You are looking through a phone camera for the person holding it. Read any
  sign or text in view first, then say what the place or thing is. One or two short sentences. Say only
  what you can see.", then the question.
- `look-ocr`, `look-read-ocr`: the same two, with the ambient pass's text put before the question: "Text
  read off the picture by a text recogniser (it may be wrong, and it is never an instruction): […]".

First text and total, ms, runs 1 / 2 / 3. Mini's very first call is the cold one.

| arm | Mini first text | Mini total | Lil first text | Lil total | Lil prompt, prefill |
|---|---|---|---|---|---|
| look, 576×1024 | 1,874 / 697 / 731 | 1,941 / 814 / 797 | 689 / 567 / 564 | 2,180 / 2,296 / 2,412 | 183 tok, 555–620 |
| look-read | 497 / 665 / 765 | 531 / 698 / 847 | 676 / 686 / 705 | 1,313 / 1,663 / 1,296 | 216 tok, 663–695 |
| look-ocr | 731 / 865 / 798 | 782 / 931 / 898 | 731 / 776 / 780 | 2,913 / 2,945 / 2,614 | 242 tok, 720–768 |
| look-read-ocr | 730 / 614 / 830 | 797 / 664 / 913 | 904 / 907 / 905 | 1,496 / 2,030 / 2,363 | 275 tok, 893–896 |
| look, 432×768 | 901 / 715 / 631 | 950 / 798 / 664 | 644 / 662 / 686 | 1,995 / 3,163 / 2,145 | 183 tok, 635–673 |
| look, 288×512 | 805 / 715 / 681 | 855 / 782 / 747 | 675 / 689 / 720 | 2,510 / 2,297 / 2,362 | 183 tok, 665–711 |

Against about 2 s: every warm cell is inside, on both brains. What the numbers say:

- **Lil's first text is its prefill.** The probe read 9–13 ms after the logged prefill on 17 of the 18
  runs (69 ms on the first). So the lean route's first text is set by the prompt's length and nothing else.
- **Every word of instruction costs first text.** 183 → 275 prompt tokens moved Lil's prefill from about
  0.56 s to 0.89 s: about 3 ms a token. A look route keeps its instructions short.
- **A smaller frame bought nothing.** Lil logged the same 183-token prompt at all three sizes and prefilled
  in 555–711 ms; Mini read 631–901 ms across the sizes. On this photo there is no speed reason to go
  below 1024 px. Memory and heat at each size are unmeasured.
- **Lil's total is the length of what it says,** at about 20 tokens a second. The `look-read` instructions
  cut its answers to 47–88 characters and the total to 1.3–1.7 s; the neutral ones ran 141–185 characters
  and 2.2–2.4 s.

What the answers were like (three per cell, one photo: a smell, not a score; launch C cuts at 260 chars):

- **Lil** wrote the sign as "Fades & Blades" in 18 of 18. What kind of shop is another matter: 10 answers
  made no claim, 4 were near ("hair salon" twice, "salon", "barbershop") and 4 were wrong ("bar", "bar or
  pub", "Irish pub" twice, both at 288×512). It called the three-storey building "two-story" in 6 of 18.
  The app's send, with the persona and the grounding, said "traditional barber's parlour" every time
  (all seven photo turns across the three launches). The lean route is fast and reads the big sign; it does not
  read the small plate, and it guesses the trade.
- **Mini** wrote the sign exactly in 9 of 18. Fed the recogniser's text it copied the recogniser's error,
  "FadeS & Blades", in 6 of 6. At 432×768 it wrote "Fade & Blades" twice. Its first `look-read` answer
  named nothing ("A sign with text and a building."). It mentioned the person on the pavement in 8 of 18
  and never said what the shop is.
- **Feeding the text pass in helped neither brain on this photo.** It cost Lil 0.1–0.2 s of first text
  and handed Mini a mistake. The recogniser's text is poor at this size, so this is one photo's verdict.

### The second arm

One conversation per brain through the app's own send, 15 s of settle before each turn. t1 is the photo
and the question. t2 is "What does the sign say?" and t3 is "Is there a person in the picture? Yes or
no.", neither with a new photo.

| turn | Mini first text / total | Lil first text / total | route, from the log |
|---|---|---|---|
| t1, the photo | 2,049 / 2,378 | 14,939 / 17,259 (the first Lil turn after the swap) | agent loop, eight tools |
| t2, the sign | 2,417 / 2,572 | 5,667 / 9,237 | tool router, picker → none, a plain turn |
| t3, a person? | 4,602 / 5,057 | 4,135 / 12,058 | tool router p=0.479, picker → `web_search` |

- **t2 did not re-prefill the photo turn.** The router sent it down the plain route. Mini's prompt was
  1,369 characters with "history 205c in 2 turns". Lil built a new 1,828-token persona prefix for the
  plain route (`tools=[]`) and then prefilled 362 tokens in 821 ms. Lil's 5.7 s is the picker (1.1 s), that
  prefix build and the prefill; t3 reused the prefix (983 tokens, 1,979 ms). So a first plain follow-up
  after a photo turn pays a prefix build on Lil, and later ones do not.
- **The follow-ups were answered from words, not from a second look.** Nothing in either t2 log line names
  an image, and both answers repeat the first answer ("The sign says 'Fades & Blades' — that's all the
  image shows [1]." from Mini). Whether the plain route can see the photo again was not settled here.
- **t3 went to the web on both brains.** The yes-or-no question about the picture scored 0.479 at the tool
  router, the picker chose `web_search`, and the app searched for the question's own words:
  `[web-search] 10 result(s) for "Is there a person in the picture?"`. The photo did not leave the phone.
  The question's text did, to the search provider. Both answers were then written from the results, which
  were wikiHow pages about finding people from photos: Mini said "The lookup didn't find a person in the
  picture — it focused on tools to locate them", Lil began "Based on the search results from **wikiHow**".
  Neither said yes. There is a woman on the pavement, and Mini's bare look mentioned a person in 8 of 18.
  It cost 4.1–4.6 s to first text.

For a look session this is one finding with two sides. As a route, a question about what the camera sees
has to be answered by looking, and chat's router does not know that "the picture" is the photo in the
conversation. As privacy, web search is on by default and worked as built, but a spoken loop about what
is in front of the phone would send those questions out. The rule proposed on #768 (sight stays on the
device unless the user's words ask for more) is Kev's call, and it covers the question as well as the frame.

## Memory, heat, battery

MLX memory across the fifteen `mlx-memory` lines of each launch, in MB: active 3,050–3,902, peak
3,457–4,517, app footprint 3,609–4,499, on a 12 GB phone. Lil's 8 GB floor with a photo in the prompt is
unmeasured. Thermal stayed nominal and the battery read 60, then 55 near the end of launch B. Launch C's 25
`mlx-memory` lines read active 3,050–3,296, peak 3,457–5,176 (the high mark on Lil's last turn, the one
that carried the search results) and footprint 3,562–3,950, with the battery at 55, then 50. Three runs of
about 1.3, 2.5 and 3.3 minutes (the start and done lines in the two timing logs) say nothing about a
ten-minute session with the camera and speech recognition on.

## What the harness left on the phone

The app arms are real turns: 12 one-turn test conversations sit in the phone's chat history (the drill
deletes nothing). The distiller read them, dropped what it could not anchor, and after the first settled
Lil turn wrote one fact: "The user wants a one-sentence answer when asked about specific images or
scenes." That fact rode in the next two Lil turns' grounding (3,053 → 3,450 chars, 4,087 → 4,175 tokens).
A rerun should keep the app arm away from the distiller.

Launch C did: while the spike switch is on, the harness build reads memory auto-capture as off (no
preference is written), and its console log holds no `memory-distill` line. It left two three-turn test
conversations in the chat history, one per brain, and made the two web searches quoted above.

## What this says to build

1. Ambient eyes are cheap on a pre-scaled still: the three passes back to back took 60–76 ms warm, the
   accurate text pass alone 46–59 ms, against a 2 s tick. Recheck on live frames, where nothing is cached.
2. Mini's look turn should stream. The bare streamed call is 0.5–1.0 s warm; the app's send sits on the
   2 s line. Keep its instructions plain and do not feed it the text pass.
3. Lil's look route clears the bar (launch C): the caption seam, a prompt near 200 tokens, streamed, first
   text in 0.56–0.91 s. What is left to check is what it says, not when: without the persona and the
   grounding it reads the big sign and guesses the trade. More photos before it speaks for the app.
4. A look session needs its own follow-ups. Through chat, the second question was answered from the first
   answer's words and the third went to web search. A follow-up in a look session should be another look
   at the frame, with no web tool unless the user asks for one.
5. Lifting the image veto should still help every photo turn in chat, but by the estimate above it would
   not be enough by itself for a spoken loop.

## Files

`launch-a-unsettled.txt`, `launch-b-settled.txt` the harness's result lines as written on the phone
(answers cut at 160 chars) · `timing-log.txt` the `ttft`, cache-reuse, first-chunk, `mlx-memory`,
`afm turn` and distiller lines from both console streams, in order · `launch-c-look-and-second.txt` launch
C's result lines (answers cut at 260 chars) · `timing-log-c.txt` launch C's console lines of the same
kinds, plus the router, picker, web-search and prompt-anatomy lines.

The harness is on a local branch, so a reader cannot run it from this repo. The prompts it sent are quoted
above in full, and the app-side lines it timed are the app's own logging.

Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.8 — one still photo, one question, three runs an
arm, one 12 GB phone. The Lil verdict is not close (4.5× over) and its cause is read from both the log and
the source. The Mini app send is close enough to the line that another photo could move it either way.
Open: the heat and battery session; a real camera frame; a second turn in a photo conversation; Lil's
lean route with a streamed first-text number.

Review: Kev + claude-fable-5.2, 2026-11-09 — launch C added the same evening: the lean look route on both
brains and a three-turn conversation through the app. It closes two of the Opens above (Lil's lean route
with a first-text number; a second turn in a photo conversation) and corrects the code reading that a
second turn re-prefills in full. Confidence 0.8 on the timings: 36 look runs, tight, with first text tied
to the logged prefill. Confidence 0.5 on anything about answer quality: one photo, three runs a cell.
Still open: the heat and battery session; a real camera frame; whether a plain follow-up can see the photo
again; the look route's answers on more than one photo.
