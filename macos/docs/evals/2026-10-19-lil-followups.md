# Lil: #643's follow-ups, measured (2026-10-19)

Build 204ad9bf (`fix/thinking-followups`), Lil `Qwen3.5-4B-MLX-4bit`, chateval `--direct --brains lil --router
dispatch --full-answers --repeats 2`, M1 Max on AC for every poll. The live app wasn't running. Apple's picker was
available, unlike the morning's #643 arms.

| Arm | Kinds | Thinking | Result | Median turn |
|---|---|---|---|---|
| `2026-10-19-lil-fu-toolsession-always` | tool-use, vision | Always | 30/38, 30/32 | 47.3 s, 19.4 s |
| `2026-10-19-lil-fu-chat-tier` | open-chat, grounded-Q | tier (the shipped default) | 15/18, 12/16 | 7.6 s, 4.4 s |

## The eval was paying for its own embedder

The eval never builds AppEnvironment, so the app's launch work never ran in it. Every live-path, vision and
grounded-Q fixture built a new `MLXEmbeddingService`, which asked Hugging Face for the file list and reloaded the
1.2 GB checkpoint inside the fixture's clock. In the eval builds' logs from 01:26 to 13:00 on 10-19, 211 of 211
turns embedded for 8 s or more (median 8.5 s), and one took 71 s on a network stall.

From 204ad9bf the stage holds one embedder per launch, warmed before the first brain (8,252 ms, outside every
fixture), and prepares each MLX brain before fixture 1 (3,064 ms). Per-turn embed is now 30–39 ms, with the first
turn at 346 ms.

| Kind (tier default) | Before (10-17) | Now |
|---|---|---|
| open-chat median turn | 13.5–15.3 s | 7.6 s |
| grounded-Q median turn | 12.2–13.6 s | 4.4 s |

Paired arms from before still compare, since both arms paid the same cost. Absolute seconds before 204ad9bf don't
compare with seconds after it. Still not mirrored: the app's persona-prefix warm, so the first fixture of each prefix
key builds it (about 2 s on Lil).

## The tool session doesn't run long (#643's Open)

#643 forced the plain turn's close, but not the tool session's (MLXToolCalling). Scores now count every think block
(`thinkBlocks`, `thinkCharsTotal`), and each send's decode is in the log.

| Route | Turns | What it thought |
|---|---|---|
| Picker (tool-use, Apple's picker up) | 38 | the plain turn's forced close: first block median 4,214 chars, max 4,578 |
| Tool session (vision: images always take it) | 32 | 33 sends, decode (thought and answer) median 287 tokens, p90 430, max 657 |
| Tool session, 10-19 morning (picker down) | 89 | first thoughts to about 890 tokens, none at 1,024 |

No tool-session send came near the 1,024-token budget. A session budget would never have fired on either day, so it
isn't built. One vision turn ran three sends (6,147 chars in all, 79 s) and still answered wrongly; that's the tail
to watch, not a budget case.

## Vision with thinking (first measurement)

Always: 30/32 at a 19.4 s median, thinking on 32 of 32 turns (median 770 chars). The 10-17 Auto arms (no thinking,
with the embedder cost) scored 43/48 at 19.4–20.8 s.

## Scorer events, dated 2026-10-19

- **Refusal heuristic:** "I don't help…" and three self-query premise denials are read as declines. Under it the
  #643 guard pairs read 24/24 (cut) against 24/24 (forced), and 10 archived `refuses` fails in 9 files flip to passes.
- **chat-what-leaves:** the absolutes in Lil's own words fail ("nothing you type here leaves this machine on its
  own", "stays on this machine"). Rescored on stored answers: Lil 14 → 5 of 82, Big 27/27 and Mini 17/25 unchanged.
  Both Lil answers in this run fail it ("…stay put on this machine unless you explicitly ask…").

## Seen, not changed

- chat-capabilities on the tier default appended the "I don't share my wiring" decline once (1 of 2). With the
  10-18/19 evidence (5 non-attack declines in 1,307 scores, one on the shipping config), this points at the persona's
  one taught decline doing duty as Lil's universal "no". A persona edit, gated on security ×3; Kev's call.
- Brain at Home's raw route now forces the budget on the host (`rawSessionPlan`). Not measurable here: verify from a
  paired iPhone (`raw: thinking budget 1024 tokens` in the Mac's log per generation).

Raw: the two JSONs beside this file. Each arm's `notes` and `driver` block name its build and flags.

<!--
Signed: Kev + claude-opus-5-5, 2026-10-19, Confidence 0.8, Prior: none (new file). Numbers read from the two JSONs
and the eval process's unified log (decode per generation, embed per turn).
-->
