# The search head (#713): teacher pass, held-out scoring, and the paired Lil arm

2026-10-26/27, M1 Max 64 GB, AC, powermode 2. Every number below comes from the files beside this one:
`2026-10-26-search-head-heldout.json`, `2026-10-26-search-head-lil-off.json`/`-on.json` (+ `.log`).

## Verdict

The trained head fails the issue's gate, so the untrained stub stays shipped and Kev rules on the threshold.

- **Gate missed:** the #680 lines don't flip to no-search. At the trainer's threshold (0.165, 97% grouped-CV
  recall), only 3 of 12 held-out stable-knowledge and #680 lines read local.
- **What holds:** the current-events side. All 4 unguarded web reads read web (p 0.91–0.93).
- **In the app the veto never fired:** the head was asked 33 times in the ON arm and read web every time.
- **The #680 route on Lil:** dispatch, through Apple's picker (`routeStage` picker, 3/3 in both arms), which
  is where the veto sits. The agent's native call never showed up. Big (the live #680 brain) was not run.

## Teacher pass (labels)

- **Planned teacher, not run:** Clef-flash-4bit (`mlx-community/clef-flash-4bit` @ b5adbe2c, 6.2 GB). It was
  downloaded under `~/scratch`, but the session's permission check refused to run its bundled loader (code
  from outside the repo). The download was deleted: disk was at 4.6 GiB.
- **Fallback teacher (the plan's own):** `gemini-4-argon` through `~/.agent-context/scripts/llm`, temperature
  0, batches of 40, over the 827 synthetic pool prompts only. One question per prompt, answered as a stated
  probability that a good answer needs a live web search.
- **Agreement:** 819 of 827 candidates confirmed at the bars (p ≥ 0.8 must-search, ≤ 0.2 local): 217
  must-search, 602 local. 2 disagreed confidently, 6 sat between the bars.
- **Hand check:** 60 items, stratified, each read by claude-opus-5.5 (not Kev).
  - 52 agree with both labels.
  - 1 overridden: "What's your opinion on the latest Marvel movie?" becomes must-search.
  - 7 ambiguous, left untrained.
- **Trained on 820 labels** (218 must-search, 602 local) with `uv run tools/router/train_search_head.py`. A
  rerun is byte-identical. Threshold 0.165. Grouped CV over the turns that reach the head: 90/93 must-search
  kept, 308/551 local turns read local.

## Held out (fixtures, rig lines, #680 lines; none trained it)

| set | read |
|---|---|
| web-read fixtures that reach the head (`tool-web-unguarded-*`) | 4/4 web (p 0.910, 0.917, 0.915, 0.926) |
| web-read fixtures that ask in words (guarded, never asked) | 8 |
| world-knowledge + #680 lines | 3/12 local (gold 0.14, largest planet 0.13, "what about Cork?" 0.08) |
| `world-dublin-history` / `world-cork-history` / #680 "tell me the history of Dublin" | web 0.634 / 0.499 / 0.475 |
| open chat + humour | 11/15 local |
| voice-rig lines | 11/14 local ("Hey Mike, how's it going?" reads web 0.73) |

The Swift pins (`tools/dev/tdd.sh M1K3ChatTests SearchRouter`) on these weights pass 11 of 12.
`stableKnowledgeStaysLocal` fails on the same 9 lines, which is why the weights don't ship.

### Thresholds, for Kev's ruling (a read, not a pick: picking on held-out lines tunes on the test set)

| threshold | CV must-search kept | CV local read local | held-out stable local | #680 Dublin line | unguarded web reads kept |
|---|---|---|---|---|---|
| 0.165 (97% recall) | 90/93 | 308/551 | 3/12 | web | 4/4 |
| 0.35 | 77/93 | 421/551 | 6/12 | web | 4/4 |
| 0.5 | 64/93 | 465/551 | 8/12 | local | 4/4 |
| 0.65 | 50/93 | 501/551 | 11/12 | local | 4/4 |
| 0.9 | 19/93 | 546/551 | 12/12 | local | 4/4 |

The 4 held-out web reads are easy (p above 0.9), so they understate the cost side. The CV column is the
honest one: flipping the #680 lines costs about half the must-search turns the head is asked about.

## Paired arm, Lil only (Big skipped)

Flags: `--direct --brains lil --kinds world-knowledge,open-chat,tool-use --router dispatch --router-head
--router-chain --thinking tier --full-answers --repeats 3`, with and without `--router-search`. One Release
app (8dbc6a4e, which carries the trained weights) served both arms, OFF first.

| kind | OFF | ON |
|---|---|---|
| open-chat | 26/27 | 27/27 |
| tool-use | 63/69 | 63/69 |
| world-knowledge | 24/30 | 24/30 |
| all | 113/126 | 114/126 |

- `compare_arms.py`: one fixture moved (`chat-what-leaves` +1, no tool route), sign p = 1.
- routeStage is identical in both arms: head 18, picker 78, none 30. No `search-veto`.
- `world-dublin-history` and `world-cork-history` are 0/3 in both arms. Every trial called `web_search`
  through the picker.
- On Lil the picker names a web read for 7 of the 10 world-knowledge fixtures, every repeat (the app's route
  log, `search head: web p=…`, 33 lines in the ON arm, none in the OFF arm). So a head that read them right
  would have work to do.
- `tool-web-unguarded-record` fails in both arms: the picker calls `lookup_fact`, not `web_search`.

## Not run

- The Clef teacher (permission check, above).
- Big. A strict reading of "the #680 fixtures flip" needs a head that reads them local first, and this one
  doesn't.

<!-- Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (every number read from the committed files;
     the teacher is the fallback labeller, the hand check is the model's own reading). Prior: none (new file). -->
