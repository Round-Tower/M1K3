# EmbeddingGemma 2 vision encoder, 2026-11-15 (#836): parity, memory, and the numbers a floor would be read from

Measurements only. **No floor is signed here and `EmbedderFloors` is untouched.** A per-modality floor is a
threshold (#713): `challenger` first, scored on a set it was not tuned on, then Kev decides. The PROPOSED figure
at the end is an input to that, not a decision.

## What ran

- Build: Debug `M1K3.app` from this branch, run directly with the fixture on stdin
  (`M1K3_SELFTEST=1 M1K3_SELFTEST_EG2REF=1`, see the header of `M1K3App/EmbeddingGemma2RefStage.swift`).
  M1 Max 64 GB. Raw output: `eg2ref-stage-output.txt` (this branch) and `eg2ref-baseline-text-only-ae8429af.txt`
  (master at ae8429af, the stage patched only to print the text digest).
- Reference: mlx-vlm 3d87e884 on `mlx-community/embeddinggemma-2-8bit@7505ef2f`, mlx pinned to 0.32.3
  (`tools/weights/make_embeddinggemma2_reference.py`; with 0.32.4 the same text vectors shift by ~1e-3).
- Images: twelve flat drawings from `tools/weights/make_embeddinggemma2_images.py` (Pillow, deterministic, nobody's
  likeness), each with a query ("the whiteboard photo about pricing") and a caption the way a Photo memory would hold
  it. **They are not photographs.** Everything below about score distributions is a statement about drawings.
- The vision path: `<bos> <boi> <image>×n <eoi> <eos>`, no prompt text (the model card: "Prefixes apply to text only.
  Pass images, video, and audio without any prefix"), under its own `image-v2` in
  `MLXEmbeddingService.imageFingerprint`. The version covers the preprocessing as well as the token layout: ANY
  change to either must bump it (a comment on `EmbeddingGemma2ImagePath.promptVersion` says so), because every stored
  image vector depends on both. (The stage prints `…/d768/…` fingerprints and the unit tests pin `…/d512/…`: the stage
  builds its service at the native 768 width to compare against the 768 fixture, the app and the tests use the stored
  512. The width is the only difference.)

## Parity (the gate: ≥ 0.999 cosine at both widths, relevance order holds)

| | result |
|---|---|
| Image vectors vs mlx-vlm, 768 | min **0.99995** over 12 images (all 0.99995 to 0.99999) |
| Image vectors vs mlx-vlm, MRL 512 (the stored width) | min **0.99995** |
| A noisy, high-frequency 4032×3024 frame (built by integer formula, 31 MB PNG through ImageIO; not a photograph) | cos768 **0.99995**, cos512 **0.99995**, 626 ms, MLX peak 837 MB |
| Text → image order, our vectors, each query vs the hardest other picture | **12/12** ok (e.g. whiteboard 0.717 vs barchart 0.610) |
| Top-1: each query finds its own picture among all 12 | **12/12** (the reference does too) |
| The 14 original text cases vs mlx-vlm | tokens 14/14, min cos 0.99985 at 768 and 512, PASS (the stage's `eg2ref summary`) |
| The 24 added caption / query text cases | tokens 24/24 ok, cos768 ≥ 0.99991 |

## The text path is unchanged

- Per-case lines for all 38 text cases (tokens, cos768, cos512, pipeline) are **identical** between master (ae8429af,
  built separately) and this branch: `diff` of the `eg2ref q-*/d-*` lines is empty.
- A SHA-256 over every text vector's float32 bytes (the 14 original cases) is `15bfaaad809770ea` on both builds:
  **bit-identical vectors**. The stage prints it (`eg2ref text digest`). The claim covers those 14 reference cases (the
  24 added caption/query cases match line for line, but they are not in the digest).
- The text fingerprint is the literal `mlx/mlx-community/embeddinggemma-2-8bit/d512/mlx-swift-0.32/prompt-v1`,
  pinned by `MLXEmbeddingServiceTests.textFingerprintIsPinnedLiterally`; the app's own self-test line shows it live.
  So no store re-indexes. The image fingerprint (`…/image-v2`) is a different string, so editing one prompt never
  re-embeds the other modality, and `EmbedderFloors.forFingerprint` does not mistake it for the measured text identity:
  it takes the unmeasured-family branch. **Caveat:** that branch returns the strictest of the known sets, and Gemma's
  bars are at or above Qwen's on every field, so numerically it is the text floors again. A test pins which branch it
  takes; getting a different number for images needs a per-modality field in `EmbedderFloors`, which is the floor decision
  and is not made here.
- Not run here: MEMEVAL / ABSEP / KEYEVAL. They embed through `embed` / `embedQuery`, which the digest above shows are
  untouched, but "byte for byte" on those fixtures is owed as its own run if the gate wants it by name.

## RAM and time for one image (Debug build, M1 Max)

| | |
|---|---|
| Text core resident, before any image | MLX active 274 MB; process footprint ~462 MB (the stage's earlier self-test work is in that) |
| After the first image | MLX active **594 MB** (+320 MB: the vision tower, bf16, unquantised); footprint ~905 MB (+~440 MB) |
| MLX peak while embedding the first image | **832 MB** with a per-layer `eval`; **1,309 MB** without it (the lazy 16-layer graph over ~2,400 patches). The per-layer `eval` costs ~30 ms an image and stays |
| Time per image, 640×480 PNG → 266 soft tokens | **~270 ms** warm median over 12; 362 ms for the first (loads the tower from a warm page cache); the very first run on this Mac, disk-cold, took 2.7 s |
| Drop (`unloadVision`) then reload | MLX active back to 274 MB; **process footprint fell only 40 to 85 MB** (the allocator keeps pages the OS has not taken back; not chased); the next image reloaded in ~310 to 350 ms |

The plan's ~191 MB text core vs ~567 MB all-modality figures are the same order: the tower adds 320 MB of weights.
Phone figures are not measured here (no device run): a 4 GB phone budget and a 12 MP photo are the open checks, see
"What is left".

## The floor inputs (cosines at MRL 512; 12 pictures, 12 queries, 12 captions)

| pair | n | min | median | max |
|---|---|---|---|---|
| text query → its own picture | 12 | **0.707** | 0.752 | 0.784 |
| text query → the other pictures | 132 | 0.514 | 0.570 | **0.681** |
| caption (as a document) → its own picture | 12 | 0.752 | 0.817 | 0.844 |
| caption → the other pictures | 132 | 0.551 | 0.633 | 0.729 |
| text query → its own caption (text↔text, for scale) | 12 | 0.794 | 0.835 | 0.861 |
| text query → the other captions (text↔text) | 132 | 0.515 | 0.616 | 0.730 |
| picture ↔ another picture | 66 | 0.663 | 0.766 | 0.872 |

- Text → image sits about **0.08 below** text ↔ text for a true match (median 0.752 vs 0.835) and about 0.05 below for
  a non-match (0.570 vs 0.616): the cone is lower and narrower, as the plan predicted.
- The dead zone for text → image is **0.681 to 0.707, a gap of 0.027**, the same thinness as the memory bar's keyword
  margin (0.027). A caption used as the query has a gap of 0.023 (match min 0.752, non-match max 0.729); a caption is a
  document, not a query, so it does not set the floor.
- **Picture ↔ picture is a different cone.** Unrelated drawings sit at a median 0.766, above the text-to-image match
  median. Nothing from the text side can be borrowed for image dedupe or an image↔image edge: the text edge bar 0.75
  would link most pairs of pictures, and the 0.95 dedupe would be untested.

### Mixing images into a text search does not crowd out the text hit

17 text queries that have a known relevant text document (12 image-queries answered by their caption, plus the 5
original ranking queries), searched over **20 text documents plus the 12 image vectors**:

- the relevant text document was pushed out of rank 1 by an image **0** times, out of the top 3 **0** times;
- images scoring above the relevant text document: **0** in total; tightest margin (relevant text doc minus best image)
  **0.027**.

What the TEXT floors would let through if image vectors shared them (memory 0.67 / chunk 0.70), summed over the same
17 queries: **14** image vectors clear 0.67 and **13** clear 0.70. Twelve of those are a picture matching its own
query. The other two (checked against the fixture): `q-pricing` ("what did we decide about the Pro price?") scoring
**0.744** against the pricing whiteboard, which is a real match, not a leak; and **0.681**, the pie chart for the
bar-chart query, the one true leak, which clears 0.67 and not 0.70. So the text floors happen to admit the true matches
and almost nothing else on this set, but the margins are 0.007 (0.70 against the weakest true match 0.707) and 0.011
(0.67 against that leak): nothing to rely on.

## PROPOSED per-modality floor (not signed; for `challenger` and Kev)

| modality pair | measured dead zone | proposed | margin each side | confidence |
|---|---|---|---|---|
| text query → picture (a new field on `EmbedderFloors`, name for `challenger`) | 0.681 (strongest non-match) to 0.707 (weakest match) | **0.69** | 0.009 above the leak / 0.017 under the weakest match | low |
| picture ↔ picture (dedupe, edge) | not measured (no matched/unrelated labels) | **none; do not reuse 0.75 / 0.95** | n/a | n/a |

Why 0.69 and why only low confidence:

- It is the middle of the one dead zone this set shows, and it is within 0.01 of the text chunk floor (0.70), so
  there is no argument for a separate number *by size*: the argument for a separate **field** is that text→image
  and text→text are different cones that happen to be close today and will not stay close for real photos.
- **n is 12 and the images are drawings.** Real photos are noisier, and captions written by a vision model are noisier
  again. The match distribution will move down and the dead zone will narrow or close; the floor must be re-measured on
  real photos (Kev's Photo memories are the natural set, with the caption as ground truth) before it is signed.
- Do not read 0.69 as "use 0.70 for images". 0.70 clears all 12 matches here by 0.007; one JPEG artefact later it would
  not.
- The lever that is likely to matter more than the absolute floor is the same one named for the text keyword probes:
  per-query normalisation (a margin over the query's own median score) rather than one bar for every query.
- The fingerprint does NOT by itself keep image search off the text numbers: `forFingerprint` resolves an image
  fingerprint to the unmeasured-family branch, which equals the text floors numerically today (see above). A separate
  image floor has to be a new field; until then image vectors would be gated by the text bars.

## What is left (not done in this slice)

- Phone: RAM and time for an image on the A-series devices, the 4 GB mobile ceiling (MLX peak is 832 MB on top of
  the 594 MB resident tower), and the iOS wiring. `embedImage` lives on `MLXEmbeddingService`, which the iOS shell does
  not construct yet (it embeds with hashing); the first caller there must sit behind `AppCore.mlxAvailable`.
- A real-photo fixture and the floor measurement on it; `challenger` on the floor; the `modality` column migration.
- A 12 MP photo on the phone: the resample is two matrix products per channel (flat, but slower than upstream's
  Metal kernel); on the Mac the 4032×3024 frame took 626 ms end to end. The decode reads up to 8,192 px on the long
  side (a 200 MB RGBA bitmap, the safety cap); a larger frame is scaled down by ImageIO, a divergence only above
  ~50 MP. Unmeasured on the phone.
- The pressure watcher has no cooldown: a machine that stays under pressure drops and reloads the tower per image
  (~0.3 s each). Follow-up.
- Intentional divergences from the reference, each a choice and not an accident (a change to any bumps `image-v2`):
  1. **Colour profile.** ImageIO converts to sRGB, Pillow reads raw bytes, so an AdobeRGB or P3 file differs from the
     Python reference by its profile. sRGB files do not.
  2. **Alpha.** A transparent pixel lands on white (the context is filled white first); Pillow's `convert("RGB")` drops
     alpha and shows whatever colour was under it (usually black).
  3. **EXIF orientation** is applied (ImageIO's transform), as the processor's `prepared` does upstream. Pillow's
     `Image.open` does not, so a rotated JPEG differs from a naive Python reference.
  Resample order matches Pillow now (horizontal pass, round to 8 bits, vertical pass, round) and there is ONE resample:
  ImageIO decodes at full size (below the 8,192 px cap it never scales, and never upscales; both are unit-tested), so
  its thumbnail filter does not stack with ours. Before the change the order was vertical-first; I did not measure that
  gap on a noisy frame, the swap is the default.
- MEMEVAL / ABSEP / KEYEVAL byte-for-byte, as noted above.
- The audio encoder (out of scope).
