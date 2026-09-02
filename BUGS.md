# Known rough edges

M1K3 is a real app used daily, and it has real bugs. This is the honest list —
each one links to its open issue. If you hit something not listed here,
[file it](https://github.com/Round-Tower/M1K3/issues); the tracker is the
source of truth and this page is a curated snapshot of the ones you're most
likely to meet.

## The ones you'll probably notice

- **Small-model small talk can be weird.** Mini (the on-device Apple
  Foundation Models tier, the first-run default) runs full retrieval and an
  agent loop even for "long day, I'm wrecked" — and can confabulate when it
  has nothing relevant to retrieve. [#102](https://github.com/Round-Tower/M1K3/issues/102)
- **Lil sometimes fabricates web-search results.** Ask it to search and if the
  web tool doesn't actually fire, a 4B model will occasionally invent a
  plausible-looking answer instead of saying so. Grounded answers cite their
  sources; a confident answer with no citations deserves your suspicion.
  [#125](https://github.com/Round-Tower/M1K3/issues/125)
- **Deep questions on Big (12B) can be slow.** Prefill on a 12B model is real:
  an ordinary question can take tens of seconds, and over MCP a heavy turn can
  blow the 120s client deadline (the async job API exists for exactly this).
  A self-referential turn can also cost a ~6s prompt-cache rebuild.
  [#121](https://github.com/Round-Tower/M1K3/issues/121)
- **Remembered facts can lose to documents in a packed answer.** When a grounded
  reply already has a full set of document passages, the grounding token budget
  can be spent before your remembered facts are added — so a personal fact you'd
  expect it to use may not appear that turn.
  [#186](https://github.com/Round-Tower/M1K3/issues/186)

## Honest model-quality notes

- Small tiers fail prompt-extraction attacks more than we'd like: our own
  published security eval scores Mini and Lil 4/7 (Big passes 7/7 on the same
  persona). Numbers, transcripts, and the harness are in
  [`macos/docs/BENCHMARKS.md`](macos/docs/BENCHMARKS.md).
  [#109](https://github.com/Round-Tower/M1K3/issues/109) ·
  [#111](https://github.com/Round-Tower/M1K3/issues/111)
- 1B–12B on-device models are not frontier models. M1K3's design assumes it:
  grounding, citations, and guardrails are structural, and the benchmark
  results ship with their flaws labelled rather than averaged away.

## Platform + plumbing

- **iOS voice mode crashes on device** (the iOS shell is early; macOS is the
  product). [#85](https://github.com/Round-Tower/M1K3/issues/85)
- **First model download burns ~1.5 CPU cores** (per-byte AsyncBytes
  iteration in the Hub downloader).
  [#80](https://github.com/Round-Tower/M1K3/issues/80)
- **A rare AppKit constraint-cycle crash** when streaming a chat turn with
  Settings open. [#77](https://github.com/Round-Tower/M1K3/issues/77)
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
-->
