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

<!-- Signed: Kev + claude-opus-5-5, 2026-09-26. Confidence 0.8 (the pick: 36/38 read-only asks on
     the real fixtures with the final prompt, 53/58 on 120 independent prompts; the live arm is in
     the table above; verify-by-launch owed). Prior: ADR 0008. -->
<!-- Review: same day, PR #420 review — the picker figures reconciled (the first scoring, 37/42,
     counted script and deep-dive asks that correctly take the agent); a guardrail after a
     successful tool now synthesises from its result instead of re-running the loop. -->
<!-- Review: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.8 — two corrections from walking build 373.
     (1) The route never ran on the Mac: ToolRouterWiring cast through SwappableInferenceProvider only,
     and the Mac responder holds RuntimeInferenceProvider (#423, BackendRouting). The table above was
     measured on the bare provider and holds for the fixed path.
     (2) A dispatched turn now has its own lean prompt (`dispatchTurnPrompt`): the date, the history, the
     result and `dispatchRules`; no knowledge excerpts, memories, small-talk rule or identity line. Under
     the plain turn's rules Mini disowned web results ("none of it sticks") and pivoted to the user's old
     threads. A/B, n=12 per arm with a prompt injection among the four scenarios: used the result 9 → 12,
     obeyed the injection 1 → 0, talked about its instructions 2 → 0, wrote HTML 3 → 0, prompt ~3,200 →
     ~1,300 chars (docs/evals/2026-09-27-mini-dispatch-poisoned-history.json). The "Leaner prompts" figure
     above is now lower still. -->
<!-- Review: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.7 — two flags, both OFF until an arm measures them.
     `toolRouterAllTiers`: any brain takes the route (Lil, Big, the pocket Mini), and Apple's model picks for
     it where it is ready, so the MLX tiers dispatch read-only tools without writing a tool call (Qwen3.5
     writes a malformed one without thinking). Arm: `M1K3_SELFTEST_CHATEVAL_ROUTER=dispatch`. ADR 0008 found
     no gain for Lil from the plain-chat route alone; dispatch is the untested half (the flag turns on both,
     so the arm measures them together). `toolGroupRouter`: a
     trained group head (ToolGroupRouter) in front of Apple's pick, despite the per-group result above: a
     device pick also needs one cue word and no write word ("schedule a meeting" abstains), a `script` read
     abstains, and every abstention falls back to the pick. Arm: add
     `_ROUTER_HEAD=1`. Its weights are an untrained stub until `tools/router/train_tool_router.py` runs on a
     Mac. -->
<!-- Review: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.7 — chains, behind `toolChain` (absent = OFF). The
     "one tool per turn" consequence above becomes up to two: a pick carries `then`, Apple's pick gets a second
     schema with an `also` slot (read-only tools or none; the single-tool schema and its 36/38 are untouched while
     the flag is off), and the group head chains two named device tools. The app runs them in order under ONE
     shared observation budget (short results whole, the rest to the long one), so a chained prompt costs one
     more header, not more text (Mini's 4,096 window), and answers once. All links failed → the agent; none
     failed, none found anything → plain; else answer from what ran, naming a link that failed. A web link after
     the head needs its own query. Cost: two long results get ~1,200 chars each, half a single tool's text, so a
     chained web answer can miss what a lone search would have carried. #510 review: the group head never picks
     a web tool (a wrong pick is egress); Apple's pick keeps that call. Arm: `M1K3_SELFTEST_CHATEVAL_ROUTER=dispatch` + `_ROUTER_CHAIN=1`; no two-tool fixture exists yet. -->
<!-- Review: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.7 — the group head is trained (it was an untrained stub).
     `train_tool_router.py` on 393 prompts: gate unchanged (threshold 0.330, CV 209/216 tool asks kept, 128/177 chat
     turns freed; the weights file did not move). Group head: dispatch floor 0.763 at 95% precision; CV at the floor:
     55 dispatched, 53 right, 53/216 tool asks covered (~25%). Synthetic data, group level: an upper bound live.
     The flags stay OFF; the eval arm (Lil and Big, flags off / routing / +head / +chains) decides each flip. -->
<!-- Review: Kev + claude-opus-5-5, 2026-10-10, Confidence 0.8 — DECIDED: the Mac turns all three flags on
     (`whenUnset: true` in its shell; an explicit setting still wins), iOS keeps them off until a phone smoke.
     The 10-09 arm had measured less than it looked: tool-use fixtures ran LocalAgent in every cell (the
     router was wired into the live path only), and the head never fired (no fixture reached 0.763), so its
     "flip" compared the same path with itself. Fixed first: tool-use takes the live path under a router mode,
     `--router off` is that path with no route, every score names its pick stage (head / picker / agent), six
     `tool-head-*` fixtures clear the floor (score_head.py; pinned in CI), Mini joined, and an `all` cell
     measures the three flags together. The 10-10 arm (×3, docs/evals/2026-10-10-router-arm-*):
     Lil off 38/48 tool-use at 8.8 s → routing 48/48 at 4.1 s → all 48/48 at 4.9 s, head 18/18 on its fixtures;
     Big 42.6 s → 14.7 s at 48/48; Mini (routed in shipping) +head 0.6 s faster at equal accuracy. Chains turn
     two-tool asks 0/3 → 3/3; their one systematic miss ("this year" sent to lookup_fact, 3/3 on every brain)
     is closed by ToolDispatch.recencyCorrected (a single pick reads the question, a chained pick its own query).
     The `all` cells on the final head (8fb7b7e3): 48/48 tool-use and 3/3 two-tool asks on all three brains,
     open-chat within one fixture of routing. Tool-use medians against routing: Lil +0.8 s (chains alone cost
     the same), Big +0.2 s, Mini −0.1 s. The script's rule says "keep off" for chains on Mini (not faster);
     they ship on anyway: level latency for 0/3 → 3/3 two-tool asks.
     The challenger (2026-10-10) held the head and chains until this re-measure; the floor stays 0.763 on
     synthetic data, an upper bound live, with write guards on all three read-only families. -->
<!-- Review: Kev + claude-opus-5-5, 2026-10-10, Confidence 0.85 — the `all` cells re-ran on the final head
     (the challenger's condition for chains): every brain held 48/48 and 3/3, so chains stay on. -->
