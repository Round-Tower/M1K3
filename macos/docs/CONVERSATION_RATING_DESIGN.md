# Conversation ratings → training data (design)

**Status:** CONCEPT (2026-08-13) — Kev's ask, verbatim intent: *"mark the
conversations that are good and bad so we can feed that into some potentially
training data in the future."* Design only; schedule via ROADMAP.md before
building.

## Why this is worth doing

The knows-me LoRA data pass has been carried on the roadmap since July with no
data-collection mechanism behind it. Tonight's live conversation (2026-08-13,
the "Quiet Corner" chat) is exactly the artifact we'd want: Lil in-character,
coherent, fast — and also exactly the artifact we'd want to EXCLUDE in part
(the fabricated web-search turn). A rating is one bit of Kev-judgement captured
at the moment he has it, instead of reconstructed months later from cold
transcripts. The pipeline turns daily driving into a curation pass that costs
one click.

## The shape

### 1. Capture — one bit, conversation-level, in the sidebar

- `rating` column on `conversations` (ChatHistoryStore, GRDB migration):
  `NULL` (unrated) / `+1` / `-1`. Payload untouched — old builds ignore it.
- UI: thumbs up/down in the sidebar row's context menu, plus a subtle chip on
  the open conversation's toolbar. No modal, no notes field in v1 — friction
  kills curation habits.
- Ratings are LOCAL, like everything else. They never sync, never phone home,
  never enter the corpus/memory graph (a rating is metadata about a
  conversation, not a fact about Kev — the distiller must never see it).

### 2. Export — JSONL, Kev-triggered, from Settings

- "Export rated conversations…" writes one JSONL per rating class:
  `good-YYYY-MM-DD.jsonl` / `bad-YYYY-MM-DD.jsonl` to a folder Kev picks.
- Record shape mirrors the eval fixtures (system persona omitted — it's
  reconstructable and A/B-frozen; storing it would bake TODAY's persona into
  data that outlives it):

  ```json
  {"conversation_id": "…", "rated": "good", "rated_at": "…",
   "brain": "lil", "turns": [{"role": "user", "text": "…"},
                             {"role": "assistant", "text": "…"}]}
  ```

- Sources/citations exported as chunk TITLES only, not content — the knowledge
  corpus contains third-party documents; training data must not become a
  side-channel copy of them.

### 3. Consumption — honest about what one bit buys

- **Good conversations** → SFT/LoRA positives (the knows-me pass: register,
  phrasing, the Cork voice). Conversation-level labels are WEAK supervision —
  a good conversation can contain a bad turn (tonight's chat: 8 good turns, 1
  fabricated web search). The export keeps whole conversations so a later
  turn-level pass can refine; v1 does not pretend to that precision.
- **Bad conversations** → primarily eval fixtures, not gradient signal. A bad
  conversation shows a failure MODE; the highest-value move is folding it into
  `ChatEvalStage` kinds (the instrument that already exists), not DPO (which
  needs paired preferences we don't collect).
- Nothing trains automatically. Export → inspect → curate → train is the
  pipeline; the app's job ends at a clean export.

## Deliberately out of v1

- Turn-level ratings (real, later; needs message-row UI without cluttering
  bubbles — maybe long-press).
- A rating surface over MCP (a visiting agent must not rate Kev's
  conversations).
- Auto-suggested ratings ("this looked good") — the entire value is that the
  judgement is Kev's.
- Notes/tags. One bit or it won't happen.

## Build estimate

Small: migration + store methods (TDD against the in-memory GRDB harness),
two UI mounts, one exporter (pure, TDD) + a Settings row. One PR.

*Signed: Kev + claude-fable-5, 2026-08-13, Confidence 0.8 (design over named,
existing seams; the weak-supervision caveat and the no-corpus/no-MCP privacy
lines are the load-bearing calls). Prior: Unknown.*
