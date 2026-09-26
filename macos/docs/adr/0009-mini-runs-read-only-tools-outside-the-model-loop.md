# 0009. Mini runs read-only tools outside the model loop

Date: 2026-09-26
Status: ACCEPTED — Kev, 2026-09-26 ("use it to invoke tools outside of the inference loop … the win I wanted in the first place")
Deciders: Kev + claude-opus-5-5
Builds on: [ADR 0008](0008-mini-routes-plain-chat-around-the-tool-palette.md)

## Context

ADR 0008 took plain chat off Mini's agent loop. The turns that do need a tool still ran it:
Mini read a ~1.9k-token tool palette, decided on a call, the app ran the tool, and a second
generation synthesised the answer. Nothing streamed. A tool turn took ~50 s.

Picking the tool without Mini was tried first. A per-group embedding router could not do it
(at 95% precision it called "What's 17 × 23?" a device question), and closed-vocabulary rules
reached ~83% precision and 40% recall on an independent set: "meeting notes" is the user's
notes, not their calendar. Which tool is a finer decision than whether a tool is needed.

## Decision

- **Mini picks, the app runs.** On a turn the router reads as needing a tool, one short
  guided generation (`AFMToolPicker`, ~1.2 s) names ONE tool from a menu of the tools on
  offer, plus its query. The app runs that tool itself (`ToolDispatch`), and the plain-chat
  route answers with the result: one streamed generation, no palette, no tool rules.
- **Read-only only.** Time, battery, Mac status, calendar, location, recent activity, notes
  search, document list, web search, fact lookup, page fetch. Anything that acts (scripts,
  the review panel, a deep dive), an `action` pick, a failed pick or a failed tool takes the
  agent turn exactly as before. A `none` pick is plain chat.
- **Only tools this turn offers.** The menu lists them and `ToolDispatch.plan` refuses any
  other, so the web toggle, the under-16 gate and the self-query gate hold unchanged.
- **An empty search is not evidence.** A search that finds nothing adds no observation; the
  turn answers as plain chat. A "found nothing" beside a well-known fact is how Mini came to
  disown Canberra.
- **Its own kill switch**, `miniToolDispatch`, absent = on.

## Consequences

- **Live, Mini, app quit** (`docs/evals/2026-09-26-mini-dispatch-*.json`, n=1 per fixture):

  | | today (agent) | router only (0008) | **router + dispatch** |
  |---|---|---|---|
  | tool use | 50.5 s · 10/10 | 50.5 s · 10/10 | **10.1 s · 9/10**, first words ~5.9 s |
  | open chat | 51.1 s · 6/8 | 10.1 s · 7/8 | **9.2 s · 8/8** |
  | humour | 50.9 s · 6/6 | 27.4 s · 6/6 | **8.5 s · 6/6** |
  | world knowledge | 51.5 s · 1/8 | 49.8 s · 5/8 | **8.8 s · 6/8** |
  | security | — | 33.0 s · 6/7 | **7.3 s · 7/7** |

  The tool-use miss ("newest Claude model" picked a notes search) led to the picker's
  "newest or latest of anything" web line. The world-knowledge misses are Mini's own facts
  (Melbourne, oxygen), on any route.
- **Leaner prompts.** A dispatched or plain turn is Mini's persona (5,581 chars) plus a body of
  ~1,200 chars (max ~2,000, a tool result included): roughly 1.7k tokens. The native tool
  session it replaces ran 5.1–5.6k tokens when it overflowed Mini's 4,096 window, which 4 of
  ~306 native tool calls did that day, failing the turn.
- **The persona.** The route keeps Mini's own trimmed persona. The standard persona was chosen
  first (voice and follow-up chips) and reversed on evidence: with a tool result in the prompt
  it narrated 12 of 39 answers in the third person ("M1K3, the AI who wears every sci-fi
  villain's grin…"); Mini's own narrated 0 of 100 across every arm, and is faster. Routed
  turns carry no follow-up chips; Mini's synthesised tool answers never did.
- The model's own tool-calling still runs for actions and uncertain picks; there are now four
  Mini routes (ReAct floor, native agent, plain chat, dispatched). A persona or security change
  owes each an eval arm (`M1K3_AFM_EVAL_ROUTER`, `M1K3_AFM_EVAL_DISPATCH`).
- One tool per turn: a question needing two (web + notes) gets the better single pick, not
  both. The agent path remains for multi-step work.
- Picker misses cluster on well-known facts sent to a lookup or a notes search; the empty-
  search rule answers those as plain chat, and a fact lookup is a cited answer.

<!-- Signed: Kev + claude-opus-5-5, 2026-09-26. Confidence 0.75 (the pick is measured offline on
     the real fixtures, 37/38 read-only asks; the live arm and an independent-set validation are
     the gate). Prior: ADR 0008. -->
