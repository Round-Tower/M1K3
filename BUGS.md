# Known rough edges

M1K3 is a real app used daily, and it has real bugs. This is the honest list —
each one links to its open issue. If you hit something not listed here,
[file it](https://github.com/Round-Tower/m1k3/issues); the tracker is the
source of truth and this page is a curated snapshot of the ones you're most
likely to meet.

## The ones you'll probably notice

- **Small-model small talk can be weird.** Mini (the on-device Apple
  Foundation Models tier, the first-run default) runs full retrieval and an
  agent loop even for "long day, I'm wrecked" — and can confabulate when it
  has nothing relevant to retrieve. [#102](https://github.com/Round-Tower/m1k3/issues/102)
- **Lil sometimes fabricates web-search results.** Ask it to search and if the
  web tool doesn't actually fire, a 4B model will occasionally invent a
  plausible-looking answer instead of saying so. Grounded answers cite their
  sources; a confident answer with no citations deserves your suspicion.
  [#125](https://github.com/Round-Tower/m1k3/issues/125)
- **Dictating while M1K3 is mid-answer silently drops your words.** The mic
  button doesn't disable while a turn is streaming.
  [#126](https://github.com/Round-Tower/m1k3/issues/126)
- **Deep questions on Big (12B) can be slow.** Prefill on a 12B model is real:
  an ordinary question can take tens of seconds, and over MCP a heavy turn can
  blow the 120s client deadline (the async job API exists for exactly this).
  A self-referential turn can also cost a ~6s prompt-cache rebuild.
  [#121](https://github.com/Round-Tower/m1k3/issues/121)

## Honest model-quality notes

- Small tiers fail prompt-extraction attacks more than we'd like: our own
  published security eval scores Mini and Lil 4/7 (Big passes 7/7 on the same
  persona). Numbers, transcripts, and the harness are in
  [`macos/docs/BENCHMARKS.md`](macos/docs/BENCHMARKS.md).
  [#109](https://github.com/Round-Tower/m1k3/issues/109) ·
  [#111](https://github.com/Round-Tower/m1k3/issues/111)
- 1B–12B on-device models are not frontier models. M1K3's design assumes it:
  grounding, citations, and guardrails are structural, and the benchmark
  results ship with their flaws labelled rather than averaged away.

## Platform + plumbing

- **iOS voice mode crashes on device** (the iOS shell is early; macOS is the
  product). [#85](https://github.com/Round-Tower/m1k3/issues/85)
- **First model download burns ~1.5 CPU cores** (per-byte AsyncBytes
  iteration in the Hub downloader).
  [#80](https://github.com/Round-Tower/m1k3/issues/80)
- **A rare AppKit constraint-cycle crash** when streaming a chat turn with
  Settings open. [#77](https://github.com/Round-Tower/m1k3/issues/77)
- **Some weight fetches sit outside the integrity choke point** (WhisperKit
  CoreML + Kokoro TTS pull from unpinned upstream refs — being closed
  methodically). [#74](https://github.com/Round-Tower/m1k3/issues/74) ·
  [#70](https://github.com/Round-Tower/m1k3/issues/70)

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
-->
