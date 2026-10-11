# Known rough edges

M1K3 is a real app used daily, and it has real bugs. This is the honest list —
each one links to its open issue. If you hit something not listed here,
[file it](https://github.com/Round-Tower/M1K3/issues); the tracker is the
source of truth and this page is a curated snapshot of the ones you're most
likely to meet.

## The ones you'll probably notice

- **Mini sometimes brings up a memory nobody asked about.** The on-device Apple
  Foundation Models tier (the first-run default) can work an unrelated
  remembered fact into a plain answer: 7 of 10 times in our own noise probe.
  [#447](https://github.com/Round-Tower/M1K3/issues/447)
- **A tool turn can come out doubled.** When a brain calls a tool natively, the
  prose it wrote before the call can land in the answer bubble, then a second
  answer follows, so the reply reads twice or garbled.
  [#179](https://github.com/Round-Tower/M1K3/issues/179)
- **A question about M1K3 itself can stall for ~6 s.** The tool palette is part
  of the prompt cache's key, so a self-referential turn rebuilds the persona
  prefix. Deep questions on Big (12B) are slow anyway: prefill on a 12B model
  is real, and over MCP a heavy turn uses the async job API rather than block.
  [#121](https://github.com/Round-Tower/M1K3/issues/121)

## Honest model-quality notes

- **Mini can recite its own instructions**, on prompt-extraction attacks and
  sometimes on plain trivia. The small tiers fail some prompt-leak attacks; the
  security eval is published with its run-to-run noise (it has swung 2/7 → 5/7
  across identical runs), not averaged away, in
  [`macos/docs/BENCHMARKS.md`](macos/docs/BENCHMARKS.md).
  [#111](https://github.com/Round-Tower/M1K3/issues/111)
- 1B–12B on-device models are not frontier models. M1K3's design assumes it:
  grounding, citations, and guardrails are structural, and the benchmark
  results ship with their flaws labelled rather than averaged away.

## Platform + plumbing

- **MCP and Brain at Home can race** when a session is re-created while the
  server is being toggled or a device is pairing (actor re-entrancy).
  [#183](https://github.com/Round-Tower/M1K3/issues/183)
- **A weight fetch still sits outside the integrity choke point** (WhisperKit's
  CoreML weights pull from an unpinned upstream ref — being closed methodically;
  Kokoro's are already pinned). [#74](https://github.com/Round-Tower/M1K3/issues/74)

<!--
Signed: Kev + claude-fable-5, 2026-08-22
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: Unknown (new file)
Context: The Show HN honesty page — every entry is a real open issue,
curated for what a new user is likely to meet. The launch draft's
"honest rough edges" paragraph sources from here. Keep it truthful on
edit: entries leave when their issue closes, never because launch
optics want them gone.
Confidence: 0.9 — content verified against the live issue tracker and
the published benchmark docs on 2026-08-22.

Review: Kev + claude-opus-4-8, 2026-09-02, Confidence 0.9 — truth pass
against the live tracker after the QA sweep. Removed #126 (dictation drop,
closed via #170) and trimmed #70 from the integrity-choke entry (Kokoro
weights now pinned, closed) — both per the "entries leave when their issue
closes" contract. Added #186 (grounding budget can spend out before the
memory lane on a document-packed turn), a user-observable rough edge the
sweep surfaced. Issue states re-checked via `gh issue view` this day.

Review: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.9 — truth pass on
launch day (the Mac App Store went live that morning). Seven entries had
closed and left per the contract: #102, #125, #186, #109, #85, #80, #77.
In: #447 (Mini works unrelated memories into plain answers), #179 (doubled
tool-turn output), #183 (MCP / Brain at Home lifecycle races). #121 kept and
reworded to what a user sees; the security note cites the eval's own
run-to-run noise instead of a fixed 4/7. Every state re-checked with
`gh issue view` the same day.
-->
