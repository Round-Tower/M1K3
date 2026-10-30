# Mini works unrelated memories into plain answers: does the memory header's wording fix it? (#447)

**No.** On 2026-10-29 the candidate clause and the shipped clause both let Mini work an unrelated memory into 14 of 15 plain answers. The candidate was reverted the same day. Per-turn data: `2026-10-29-mini-memory-noise.json`.

## Setup

- **Brain:** Mini (Apple Foundation Models) through `MiniRetrievalNoiseEvalTests`, run under `swift test` on macOS 27.0 with M1K3 quit, paced at 10 s.
- **Prompt:** the real `plainTurnPrompt`. The `nochunks` arm carries no excerpts and two unrelated memories (a Galway half marathon, a sourdough starter called Dough Nut). That arm is what a chat turn gets since #438.
- **Shipped clause:** "Weave facts in naturally;"
- **Candidate clause:** "Mention a fact only when it helps answer what they asked;"
- **Pairing:** both clauses ran in the same run, on the same probes, 3 trials each.
- **Scoring:** memory noise is any mention of galway, dough nut, sourdough or trail in an answer to a question that isn't about them. An empty answer counts as an error, never as clean. Every hit was read by hand, and all were real.

## Results

| | shipped | candidate |
|---|---|---|
| Memory noise (5 probes × 3) | **14/15** | **14/15** |
| Excerpt noise | 0/15 | 0/15 |
| Weekend control (memory relevant) | 3/3 | 3/3 |
| Sourdough recall control | 3/3 | 3/3 |
| Seal control (excerpt answers it) | 2/3 | 3/3 |
| Blind recall, MemoryEvalFixtures (22 pairs) | 21/22 | 21/22 |
| Blind leak, MemoryEvalFixtures (11 pairs) | 3/11 | 2/11 |
| Empty answers | 0 | 0 |

**Pass bar, set before the run:** at most 3/15 memory noise, with the controls held. The candidate scored 14/15, so it was reverted.

## What the answers show

- **Mini pulls the memories in however the header asks.** "Why is the sky blue?" got "...the last thing you'd need to know about Galway or Dough Nut". "How's my battery?" got the sourdough starter.
- **Wording is not the lever on Mini.** A fix has to stop unrelated memories reaching Mini's plain turn: for example a relevance rule before the prompt is built, or memories only for questions about the user. That is structural and waits for after the freeze. The same block reaches Lil and Big, and they were not measured here.
- **Seen in passing (separate issues):**
  - "How long do I boil an egg for?" got "Not in what I can see." in every trial, a wrong refusal on plain trivia.
  - The joke probe came back wrapped in unrequested HTML.
  - Some blind answers opened with the wiring decline ("I don't share my own wiring").
- **Marker caveat:** the blind recall marker "emoji" missed one answer that said "emojis", and that miss happened in the shipped arm. Both arms would read 21/22 or better with a plural-tolerant marker.

## Reproduce

The commands are in `MiniRetrievalNoiseEvalTests`' header. The baseline arm is now the shipped prompt, and `+candidate` swaps in the clause from `M1K3_AFM_EVAL_NOISE_CLAUSE`.
