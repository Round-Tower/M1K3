//
//  AgentRAGResponder.swift
//  M1K3Chat
//
//  The always-on tool-calling responder: every chat message runs the LocalAgent
//  ReAct loop with injected tools (web search, datetime, system status, …).
//
//  Retrieval still happens FIRST, exactly like RAGResponder — the chunks come
//  back as typed sources so ChatSession's citation validation is unchanged, and
//  a model that opens with CONCLUSION: costs exactly one generation, same as
//  plain RAG. The conclusion's tail streams live via the agent's
//  ConclusionStreamSplitter; tool use surfaces through onActivity; and if the
//  agent throws or comes back empty, we fall back to the plain grounded prompt
//  rather than failing the turn (AFM guardrails, format collapse — never a
//  dead bubble).
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.8, Prior: Unknown
//  Context: tools are injected by the app layer (M1K3Chat does not link
//  M1K3AgentTools); web_search is only in the list when the user's setting
//  allows it.
//  Review: Kev + claude-fable-5, 2026-06-12, Confidence 0.85 — RULES line in
//  both styles routing self-questions (configuration/design/abilities) to the
//  persona instead of document search; the soft fix for meta-question
//  confabulation, taken over a pre-generation router (brittle both ways).
//  Review: Kev + claude-opus-4-8, 2026-06-13, Confidence 0.9 — retrieval now
//  uses store.searchGrounding (two-lane doc+memory budgets, memoryTopK) so the
//  document corpus can't crowd memory recall out of a single top-K. Fixes the
//  live open-chat miss (M1K3 forgot the user's own city). verify-at-⌘R.
//  Review: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.9 — gather-then-
//  synthesise on the native path: once a tool runs, suppress the model's loose
//  in-loop conclusion (gemma free-forms content-free filler and ignores the
//  results) and answer explicitly over the gathered observations via fallBack.
//  ReAct's CONCLUSION: contract is untouched (gated on style == .native).
//  Diagnosed live — the conclusion was filler, not empty; instrument first.
//  Review: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.85 — brain-aware
//  conversation replay: `grounding` now takes a `HistoryWindow.Budget` (per-tier,
//  from `HistoryBudgetPolicy`) so the multi-turn window scales to the brain. The
//  compose-fix that briefly lived here (trust `conclusionWasStreamed`) was
//  SUPERSEDED by the gather-then-synthesise approach above (verified on gemma,
//  the brain that actually fills); the persona-voiced composed answer on Qwen is
//  a tracked follow-up. Only the history-budget threading survives this merge.
//  Review: Kev + claude-fable-5, 2026-07-12, Confidence 0.85 — self-query
//  router (prompt-hardening v2, code-side): SelfQueryGate short-circuits
//  retrieval and withholds the corpus-reaching tools on questions about M1K3
//  itself, enforcing the persona's SELF rule in code. Narrow leak-class classifier,
//  NOT the general pre-generation router rejected 2026-06-12 — a miss falls
//  back to the prompt rule (today's behaviour); boundaries pinned in tests.
//  Review: Kev + claude-fable-5, 2026-07-20, Confidence 0.85 — the grounding-
//  size safety cap: right after GroundingGate.partition, GroundingBudget.fit
//  caps the combined chunks+memories to ~1100 tokens (measured, PR #65) before
//  anything renders them, closing the near-miss where gemma-4's grounded-Q
//  worst case landed at 2998/3000 reserve tokens. A `.notice` breadcrumb fires
//  only when the cap actually changed something — see GroundingBudget.swift.
//  (This line used to read "no-op when the provider isn't `TokenCounting`
//  (AFM/Mini)" — that exemption was the 2026-08-03 Mini bug. The cap now
//  applies on every tier, estimating when there is no exact tokenizer.)
//  Review: Kev + claude-fable-5, 2026-08-23, Confidence 0.8 — the hands:
//  when propose_script is offered, the generative carve-out gains ONE exception
//  (a runnable script routes to propose_script, not a pasted code block). The
//  absolutist "no tools" prohibition is KEPT for every other generative ask so
//  gemma never over-tools a poem/story — a review fold after the first draft
//  dropped it (would have let "write a story about the moon landing" fire
//  web_search). On-device A/B owed on the Big/gemma tier: script→sheet,
//  poem→inline, generative-with-a-fact→still-no-tool.
//  MurphySig: kevin+claude-fable-5 2026-08-23 confidence=0.8 — prompt content
//  is pin-tested; the behavioural change on gemma is verify-at-⌘R.
//  Review: Kev + claude-fable-5.1, 2026-09-05 — fallbackPrompt filters the trace ONCE (survivors) and derives both
//  the observations and the page-read flag from it (#209 review 2: duplicated predicate).
//  Review: Kev + claude-fable-5.1, 2026-09-04 (late) — a user-given address is a READ:
//  `fetchPageRouting` (offered-only) + one shared `describeOnlyRouting`; the search-deepen
//  rule is scoped to "after a search"; open_link never names fetch_page when it is absent.
//  Review: Kev + claude-fable-5.1, 2026-09-04 (late) — `pageReadSynthesisLine` in the synthesis
//  prompt when a page was read; the native-synthesis log line says what it is.
//  Review: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85 — Todos v1: `todoContextProvider` + `todos:` on
//  grounding/groundingBody — the OPEN TODOS block sits after the memory block and before the ambient page; nil
//  is byte-identical (pinned by TodoGroundingTests).
//  Review: Kev + claude-fable-5.1, 2026-09-10 — `recentActivityRouting`, offered-only: "what happened lately" is a
//  READ of the stores through recent_activity, never a reconstruction from the history window (pinned).
//  Review: Kev + claude-fable-5.1, 2026-09-11 — the small-talk line on both native rule sets now
//  says what to DO with a greeting (reply in your own voice, pick up one real thread) instead of
//  only what not to call; the memory block header speaks TO the user and forbids bracketed cites
//  (byte-replay showed "Kev's been…" third-person openers and "[Water with lemon]" cites).
//  Review: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 — #286: `memoryBlock` filters out
//  SelfNoteClassifier-flagged (wiring-shaped) memory hits before rendering "WHAT I KNOW ABOUT
//  YOU" — a visitor note describing M1K3's own tooling is knowledge about the app, not the user,
//  and was tripping the SELF/WIRING decline on unrelated questions. Review 3 fold: `usableMemories`
//  is the ONE filter behind both `hasGroundedKnowledge` and `memoryBlock` — a wiring-only hit no
//  longer reports "grounded" (and buys a think phase) for a block that will not render. Review 4
//  fold: the same filter runs right after `GroundingGate.partition`, BEFORE `GroundingBudget.fit` —
//  a wiring hit that outranked a real memory was spending the budget's last unit and then rendering
//  as nothing (pinned end-to-end by `wiringNoteDoesNotSpendTheGroundingBudget`).
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the gate log speaks BEFORE the wiring filter (review 12 on #288):
//  `logGateDecision`'s kept/gated verdict is the relevance floor's alone, and a wiring-shaped drop gets its own
//  count line, so a floor tuned from the unified log never absorbs a #286 drop. Log-only; `usableMemories` stays pinned.
//  Review: Kev + claude-opus-5, 2026-09-12, Confidence 0.85 — Kev: "isn't searching the internet much … coding /
//  document generation is not being invoked." `currentWorldRouting` (the newest, this year's results, unrecognised
//  names, even with notes injected), `generativeCarveHead` (build/make/a whole web page; a CAN-you question is
//  answered by doing it), the scripts carve's "a web page or a document is not a script", and "how busy it's been"
//  on the recent_activity line. Wording byte-replayed on Lil before landing (see each constant); pinned by
//  WebAndMakingRoutingTests. Residual: an unfamiliar name Lil is sure it knows ("OpenAI's Astra") still isn't searched.
//  Review: Kev + claude-fable-5.1, 2026-09-12 — `replayFraming` under the history block: Mini on
//  Golden Gate replayed its previous answer (and chips) as the next turn (launch snag list).
//  Confidence 0.7 (verify-by-launch on a two-turn Mini chat).
//  Review: Kev + claude-opus-5, 2026-09-14, Confidence 0.8 — on a ReAct turn (Mini) the RULES
//  leave the per-turn grounding and ride the loop's stable head (`reactParts`), so AFM can
//  prewarm them; `reactPromptPrefix(tools:)` is that head for the launch warm, pinned byte-equal
//  to the live prompt (ReActStableFirstResponderTests). The ReAct rules say notes appear BELOW
//  them; the native layout and its wording are untouched. Gated by the live-path Mini eval.
//  Review: Kev + claude-opus-5, 2026-09-14, Confidence 0.85 — a ReAct turn can now stream a
//  preamble before the tool call it ends with (LocalAgent's trailing-action rule), so "streamed"
//  no longer means "answered": an empty conclusion after a streamed preamble falls back too, a
//  paragraph on, with the fallback's snapshots turned into deltas so they read once after the
//  preamble (ReActPreambleFallbackTests). The agent-threw fallback gets the same care.
//  Review: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.8 — the tool router's plain-chat
//  route (`plainRouteProvider`, nil by default = byte-identical). A turn ToolNeedRouter reads
//  as chat runs `runPlainTurn`: one streamed generation over the turn's context, replay and
//  grounding with tool-free `plainRules`; an empty stream falls back to the agent turn. Why:
//  Mini's chat turn measured 51.5 s with the palette, 13.4 s without (PlainTurnRouteTests).
//  Review: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.8 — a dispatched turn gets its own
//  lean prompt (`dispatchTurnPrompt` + `dispatchRules`): date, history, result, rules; no
//  excerpts, memories, small-talk rule or identity line (`observationRule` is gone). Under the
//  plain rules Mini disowned web results and pivoted to old threads (build 373). A/B n=12: used
//  the result 9 → 12, injection obeyed 1 → 0, prompt ~3,200 → ~1,300 chars (ADR 0009 review).
//  Same day, #424 review: the empty-answer synthesis gets the framed result + age clause (was raw).
//  Review: same day (2), 374 over MCP — a well-known fact survives a lookup that missed it
//  (Wikipedia returned the rental market for "capital of Australia"); a pick this turn doesn't
//  offer is a plain turn, not an agent turn that overflowed Mini at 4,423 tokens.
//  Review: same day (3), #428/#349 — the plain turn takes the identity line without the date,
//  and its small-talk rule drops "pick up one real thread (what they said, a memory of them,
//  the hour)". Small talk opened on the date 11/16 and invented a shared past 6/14; with Mini's
//  curiosity beat gone too, 1/16 and 2–3/14 (MiniInventedMemoryEvalTests).
//  Review: same day (4), #427 — an action pick's agent turn is offered only the tools that act
//  (`ToolDispatch.actionPalette`); with the whole palette Mini's native session overflowed at
//  4,282 tokens (375 over MCP). None on offer act → a plain turn. `runDispatchedTurn` returns
//  a `DispatchOutcome` carrying the palette instead of a Bool.
//  Review: same day (5), #430 — a plain turn carries no knowledge excerpts and no "No stored
//  knowledge matched" head, and lists none as sources. Retrieval's least-bad match leaked into
//  3/10 noise probes (0/10 without); the router sends every document question probed to the
//  tools (15/15), where the excerpts stay. Memories stay: they didn't leak.
//  Review: same day (6), #438 review — the rule keys on the router's verdict, not the lane that
//  answers: a chat verdict carries no excerpts even into the agent turn a blank plain turn hands
//  to, and a tools verdict keeps them in its plain fallbacks (only the chat route was measured).
//  Sources come from the same `turnChunks`; before, both fallbacks listed the wrong set. A
//  dispatched tool's answer still lists excerpts it never read (pre-existing). Confidence 0.8.
//  Review: Kev + claude-fable-5.1, 2026-10-10 — `styleClauseProvider`: a third turn clause, eval-only (the
//  think-steer arms: terse / emoji / soft cap). nil everywhere in production.
//  Review: Kev + claude-opus-5-5, 2026-10-04 — `egressClauseProvider` + `turnClauses()` (#482): the egress
//  facts ride every prompt the age clause rides (agent, plain, dispatch, synthesis), pinned in three suites.
//  Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-10-07 — a dispatched turn runs a chain (`ToolDispatch.chain`): the
//  pick and up to one more read-only tool, results under one shared budget, one answer. All failed → the
//  agent; none failed and none found anything → plain; else answer from what ran. A single pick behaves
//  as before (DispatchTurnTests unchanged). Confidence 0.75.
//  Review: Kev + claude-fable-5.1, 2026-10-09 — a cancel in the dispatch chain is no tool failure (#512).
//  Review: Kev + claude-fable-5.1, 2026-10-09 — `recentActivityRouting` settles "busy": busiest / most
//  active days means activity on this device → call recent_activity, never ask which kind of busy. Lil
//  (Qwen3.5) asked ~6/16 on `tool-recent-busiest`. Wording pinned (RecentActivityRoutingTests); the
//  5× Lil replay is owed. Confidence 0.7.
//  Review: Kev + claude-fable-5.1, 2026-10-09 (fold) — `excludedKinds` (caption memory): per-responder withhold
//  threaded into `searchGrounding` and the `collectedSources` citation gate. The MCP ask passes
//  KnowledgeKind.withheldFromMCP; the chat and local asks pass nothing (byte-identical).
//  Review: Kev + claude-opus-5-5, 2026-10-10 — the dispatched pick passes `ToolDispatch.recencyCorrected`
//  before it is planned.
//  Review: Kev + claude-fable-5.1, 2026-10-11 — the turn's thinking decision is made once and set as
//  `InferenceIntent.thinking` around the whole turn task (#555): plain route and synthesis now honour Auto.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — #555 review fold: `runAgentTurn` takes the turn's one decision
//  (`thinkingEnabled`) instead of re-reading the mode, so a mid-turn voice toggle can't split the turn.
//  Review: Kev + claude-opus-5-5, 2026-10-16 — `voiceClauseProvider`: a voice turn's room line (what the
//  mic heard, SoundContextGate) joins `turnClauses()`. A clause, never the question: it stays out of the
//  chat history and memory distillation by construction.
//  Review: Kev + claude-opus-5-5, 2026-10-16 — `promptAnatomy` logs a plain/dispatched prompt's history-vs-rest
//  split (the challenger's step 0 before a history cache or a voice history cap on Big).
//  Review: Kev + claude-opus-5-5, 2026-10-16 (pre-push review fold) — `runPlainTurn` reads the history
//  budget once, so the anatomy line describes the window the prompt was built with (voice mode can flip
//  between two reads).
//  Review: Kev + claude-opus-5-5, 2026-10-17 — the anatomy line counts the earlier-user trace (` · earlier N`, #626),
//  so the voice rig can see it on a live turn without logging any text.
//  Review: Kev + claude-opus-5-5, 2026-10-17 — #622: with history, a tools verdict on a turn that points back at
//  this chat (`ToolNeedRouter.pointsBackInChat`) answers from the replay, logged "(points back in this chat)";
//  a web read on an "open the website" ask becomes the action pick (`ToolDispatch.openCorrected`). Confidence 0.75.
//  Review: Kev + claude-opus-5.5, 2026-10-17 — a plain or dispatched turn that thinks to the cap
//  without closing `</think>` no longer counts as answered: it answers once more under
//  `withThinking(false)`, after the shown reasoning, and an empty retry hands over to the
//  fallbacks. Live on Always-think, Lil's reasoning-only stream left an empty bubble.
//  Confidence 0.8 — the retry pays a second prefill; verify-by-launch owed.
//  Review: Kev + claude-opus-5-5, 2026-10-18 — the thinking cap: open reasoning past `thinkingBudget`
//  (default `ThinkingPolicy.thinkingBudgetCharacters`) stops the think phase and takes the straight-answer
//  path above. Confidence 0.75 — the capped arm decides the figure.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — a brain that closes its own thought (`ThinkBudgetForcing`, Lil at
//  1,024 tokens) moves the cut to a net above its budget, asked per turn so a hot-swap and both shells follow.
//  A 4,000-character cut would race the forced close (10 of 38 forced hard thoughts ran past it). Confidence 0.8.
//  Review: same day (pre-push review fold) — the turn's cut rides the anatomy notice (` · cut N`): the app's
//  façade forward is compile-checked only, so a launch is how 8,192 against 4,000 is told apart. Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — an image turn on a brain that can't call tools (Brain at Home; an
//  audition model with no dialect) is declined by name before retrieval: the ReAct floor drops images, so the phone's
//  thumbnail was answered unseen. `imageNotCarriedReply`; the availability throw still comes first. Confidence 0.85.
//  Review: same day (pre-push review fold) — the decline's pronoun follows the count ("what's in them") and a blank
//  name trims to "This brain".
//  Review: Kev + claude-opus-5-5, 2026-10-19 (privacy gate fold) — `turnClauses` hands the egress answer to the
//  provider's persona variant: pocket's drops the verdict lead the 1.2B copied into unrelated answers.
//  Review: Kev + claude-opus-5-5, 2026-10-20 — the dispatched pick goes through `ToolDispatch.corrected` (recency → open → personal):
//  "what did I decide …" picked lookup_fact, the dispatch prompt carried Wikipedia's "2003 in music" and no memory,
//  and Lil read the egress clause as the user's pick of Private Cloud Compute. Confidence 0.75 (pinned; the router
//  chateval arm with `--router dispatch` is owed).
//  Review: Kev + claude-opus-5.5, 2026-10-23 — #670: implicit grounding runs HashingKeywordLane when no document
//  cleared the floor (the phone's hashing arm only). Confidence 0.8 (pinned; the Mini turn is verify-by-capture).
//  Review: Kev + claude-fable-5.1, 2026-10-25 — the stream the consumer reads forwards the turn's and logs
//  `turn first token:` off its first real chunk (TurnPhaseTimeline); and `postToolAnswerPolicy`
//  (PostToolAnswer, default `.synthesise` = byte-identical): every native tool turn decoded an answer it threw
//  away (`onConclusionToken` dropped it, `synthesiseOverEvidence` was always true) and decoded again. The `use`
//  arm keeps an answer-shaped conclusion and synthesises only after a preamble; paired chateval decides whether
//  any tier's default moves. Confidence 0.8 (pinned both ways; the live gain is the eval's to show).
//  Review: Kev + claude-fable-5.1, 2026-10-26 — `groundingWithStablePrefix`: the native turn also hands the agent
//  where its grounding stops being stable (context line + replay), the tool session's cross-turn tail cut (the LCP
//  cut lagged a turn).
//  Review: Kev + claude-opus-5-5, 2026-10-26 — `ToolDispatch.documentCorrected` after `corrected`: a lone lookup_fact
//  pick when the gate kept a document chunk answers on the plain route over those chunks (grounded-long: torque went
//  to lookup_fact 6/6 and never read the manual). Web picks keep the 09-27 lean prompt. Confidence 0.75 (pinned; paired
//  grounded-long + cross arm on Lil/Big: torque 0/6 → 6/6, cross 17/18; Mini unmeasured).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold on #711) — `keptUserDocument`: a kept chunk from an
//  imported `.conversation` (another assistant's old answer, on the document lane since #711) no longer counts as the
//  user's own document for `documentCorrected`, so an import can't silently turn world-fact lookups into plain turns.
//  Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-26 — `turnNoteProvider` (#697): Cool Head's line for the send that eased
//  effort, read once per turn after the defer, availability and image gates and sent as `.note` on the activity
//  channel. It never reaches `turnClauses()` or a prompt builder: every prompt byte is unchanged, pinned by test.
//  Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-26 — the search head's veto (#713) after `documentCorrected`: when the
//  route carries `staysLocal` and the pick reads the web, a local verdict takes the web reads out
//  (`searchCorrected`); a pick left empty answers on the plain route with the turn's chunks and history. Logged
//  (`search head:`) and recorded as a `search-veto` stage for the eval. Chat verdicts and native agent calls are
//  untouched. Confidence 0.8 (pinned; flagged off, the head untrained until its teacher pass and paired arm).
//  Review: Kev + claude-opus-5.5, 2026-10-26 (2) — the head is asked only on a `ToolDispatch.vetoable` pick: an
//  explicit web ask or a question about now never reaches it. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-26 (3) — the veto's log names the web reads it dropped (a chain's web link
//  can be its tail, where the head tool was named). Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-28 — a dispatched turn's shares are measured on
//  `ToolDispatch.promptText`, the text the model reads (a web search's URLs as hosts), so a chain splits the
//  budget by what each result costs the prompt. The trace keeps the raw output for the Sources footer. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-29 — #447: the memory header says "Mention a fact only when it helps
//  answer what they asked" for "Weave facts in naturally", which had Mini work unrelated memories into 7 of 10
//  plain answers. Every tier and route renders this block, but only on a turn where a memory cleared the gate,
//  so memory-free prompts are byte-identical. Confidence 0.7 until the paired Mini run and the blind set land.

import Foundation
import M1K3Agent
import M1K3Inference
import M1K3Knowledge
import os
import Synchronization

public struct AgentRAGResponder: RAGResponding, Sendable {
    private static let log = Logger(subsystem: M1K3Log.subsystem, category: "responder")
    private let store: KnowledgeStore
    private let embedder: any EmbeddingService
    private let provider: any InferenceProvider
    /// Evaluated fresh each turn so a settings change (e.g. the web-search
    /// privacy toggle) applies immediately — a disabled tool is never even
    /// visible to the model.
    private let toolsProvider: @Sendable () -> [any AgentTool]
    private let topK: Int
    /// Memories get their OWN retrieval budget (see `KnowledgeStore.searchGrounding`)
    /// so document volume can't crowd them out of recall.
    private let memoryTopK: Int
    private let maxIterations: Int
    /// Hits the model retrieved itself via search_knowledge — drained after
    /// the stream and merged into the turn's sources (see `collectedSources`).
    private let sourceCollector: ToolSourceCollector?
    /// The user's reasoning preference, read fresh each turn (Settings picker:
    /// Auto / Always think / Fast answers) — same per-turn pattern as tools.
    private let thinkingModeProvider: @Sendable () -> ThinkingMode
    /// Open reasoning, in characters, a plain or dispatched turn streams before it is cut
    /// (nil at init: `ThinkingPolicy.thinkingBudgetCharacters`). A brain that forces its own close
    /// overrides it per turn with a net above its budget (`thinkingCut`).
    private let thinkingBudget: Int
    /// The active brain's display name (e.g. "Lil M1K3"), read fresh each turn so
    /// a runtime hot-swap is reflected — same per-turn pattern as `toolsProvider`.
    /// Empty when unknown (tests / simple callers); the context line omits it then.
    private let brainNameProvider: @Sendable () -> String
    /// Per-turn override for the agent-loop iteration cap, read FRESH each turn so
    /// a thermal "ease off" (CoolHeadPolicy) takes effect live without rebuilding
    /// the long-lived responder. `nil` → the fixed `maxIterations` base, so the
    /// default path is byte-identical. Stays an opaque `() -> Int`: the thermal
    /// level enum lives in M1K3LanguageModel, which this module deliberately does
    /// NOT link (the dependency-direction trap) — the enum→Int map is the app's job.
    private let maxIterationsProvider: (@Sendable () -> Int)?
    /// Whether the active brain biases toward fast answers (Mini/Lil), read fresh
    /// each turn like the other providers so a hot-swap takes effect immediately.
    /// Feeds `ThinkingPolicy.shouldThink(fastByDefault:)` — the speed tiers skip the
    /// think phase on plain grounded lookups. Default `false` = the heavy-tier
    /// behaviour, so existing callers/tests are byte-identical.
    private let fastThinkingProvider: @Sendable () -> Bool
    /// The conversation-replay budget, read FRESH each turn (same per-turn pattern
    /// as the other providers) so a brain hot-swap re-sizes the window immediately —
    /// wide on the dense-Qwen tiers, clamped under gemma-4's 8192 rotating window.
    /// Defaults to the conservative shipped window so an unwired caller is unchanged.
    private let historyBudgetProvider: @Sendable () -> HistoryWindow.Budget
    /// Cool Head's heavy-generation defer, read FRESH each turn. `true` (critical
    /// thermal + opt-in ON) makes the turn skip the heavy retrieve+generate and
    /// answer with an honest deferral instead of piling onto a throttling Mac.
    /// `nil` → never defers, so the default path is byte-identical. Opaque
    /// `() -> Bool` for the same dependency-direction reason as `maxIterationsProvider`:
    /// the CoolHeadLevel enum lives in M1K3LanguageModel, which this module doesn't link.
    private let defersHeavyGenerationProvider: (@Sendable () -> Bool)?
    /// Cool Head's line for this turn (#697): non-nil only on the send whose pressure just eased
    /// effort. Read ONCE per turn, after the gates (a turn that never runs takes no line), and sent
    /// as `.note` on the activity channel, never into a prompt: the line is the app's fixed copy,
    /// not context, so the brain never reads it and every prompt byte is unchanged. `nil` → no read.
    private let turnNoteProvider: (@Sendable () -> String?)?
    /// The grounding token ceiling, read FRESH each turn like the other
    /// providers so a brain hot-swap re-sizes it immediately.
    /// `GroundingBudget.defaultTokenBudget` was DERIVED from Big's 3000-token
    /// reserve in an 8192-token window; on Mini's 4096 window the same number is
    /// 27% of everything the model has. `GroundingBudgetPolicy` sizes it per
    /// tier. Defaults to the old constant so unwired callers are byte-identical.
    private let groundingBudgetProvider: @Sendable () -> Int
    /// The age-band prompt clause, read FRESH each turn (same per-turn pattern)
    /// so an age-range declaration takes effect on the next turn.
    private let ageClauseProvider: @Sendable () -> String?
    /// What can leave the device this turn (`EgressDisclosure.clause`, #482), read
    /// FRESH each turn — web search, a Private Cloud Compute pick — or nil.
    private let egressClauseProvider: @Sendable () -> String?
    /// An eval-only clause on HOW to reason (the think-steer arms, 2026-10-10);
    /// nil in production — no shell passes one.
    private let styleClauseProvider: @Sendable () -> String?
    /// What the mic heard during a voice turn ("music (guitar)"), set by the voice shell for
    /// that turn only (TurnClauseSlot); nil for typed turns.
    private let voiceClauseProvider: @Sendable () -> String?
    /// What's open beside the chat right now (the review panel's rendered page),
    /// or nil — the app reads a snapshot the web view updates on load.
    private let browserContextProvider: (@Sendable () -> BrowserContext?)?
    /// The user's open todos, already rendered (TodoGroundingBlock in
    /// M1K3Todos — this target stays list-agnostic), or nil for none. Per-turn
    /// content beside the memory block, never the cached persona prefix.
    private let todoContextProvider: (@Sendable () -> String?)?
    /// The tool router's plain-chat route, read per turn. nil (the default, and
    /// every brain but Mini with the flag on) is today's agent turn, byte for byte.
    private let plainRouteProvider: (@Sendable () -> PlainTurnRoute?)?
    /// What a native tool turn does with the loop's own post-tool answer (plan item 2, 2026-10-25):
    /// `.synthesise` (the default — today's second generation) or the `.use` arm (`-postToolAnswer use`).
    private let postToolAnswerPolicy: PostToolAnswerPolicy
    /// Kinds this responder never grounds on, cites, or lets a tool hand back
    /// (caption memory, 2026-10-09): the MCP surface passes
    /// `KnowledgeKind.withheldFromMCP`; local surfaces leave it empty.
    private let excludedKinds: Set<KnowledgeKind>

    public init(
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        provider: any InferenceProvider,
        toolsProvider: @escaping @Sendable () -> [any AgentTool],
        topK: Int = 5,
        memoryTopK: Int = 5,
        maxIterations: Int = 5,
        sourceCollector: ToolSourceCollector? = nil,
        thinkingModeProvider: @escaping @Sendable () -> ThinkingMode = { .auto },
        thinkingBudget: Int? = nil,
        brainNameProvider: @escaping @Sendable () -> String = { "" },
        fastThinkingProvider: @escaping @Sendable () -> Bool = { false },
        historyBudgetProvider: @escaping @Sendable () -> HistoryWindow.Budget = { .default },
        maxIterationsProvider: (@Sendable () -> Int)? = nil,
        defersHeavyGenerationProvider: (@Sendable () -> Bool)? = nil,
        turnNoteProvider: (@Sendable () -> String?)? = nil,
        groundingBudgetProvider: @escaping @Sendable () -> Int = { GroundingBudget.defaultTokenBudget },
        ageClauseProvider: @escaping @Sendable () -> String? = { nil },
        egressClauseProvider: @escaping @Sendable () -> String? = { nil },
        styleClauseProvider: @escaping @Sendable () -> String? = { nil },
        voiceClauseProvider: @escaping @Sendable () -> String? = { nil }, // swiftformat:disable:next unusedArguments
        browserContextProvider: (@Sendable () -> BrowserContext?)? = nil,
        todoContextProvider: (@Sendable () -> String?)? = nil,
        plainRouteProvider: (@Sendable () -> PlainTurnRoute?)? = nil,
        excludedKinds: Set<KnowledgeKind> = [],
        postToolAnswerPolicy: PostToolAnswerPolicy = PostToolAnswer.policy()
    ) {
        self.store = store
        self.embedder = embedder
        self.provider = provider
        self.toolsProvider = toolsProvider
        self.topK = topK
        self.memoryTopK = memoryTopK
        self.maxIterations = maxIterations
        self.sourceCollector = sourceCollector
        self.thinkingModeProvider = thinkingModeProvider
        self.thinkingBudget = thinkingBudget ?? ThinkingPolicy.thinkingBudgetCharacters
        self.brainNameProvider = brainNameProvider
        self.maxIterationsProvider = maxIterationsProvider
        self.fastThinkingProvider = fastThinkingProvider
        self.historyBudgetProvider = historyBudgetProvider
        self.ageClauseProvider = ageClauseProvider
        self.egressClauseProvider = egressClauseProvider
        self.styleClauseProvider = styleClauseProvider
        self.voiceClauseProvider = voiceClauseProvider
        self.browserContextProvider = browserContextProvider
        self.todoContextProvider = todoContextProvider
        self.defersHeavyGenerationProvider = defersHeavyGenerationProvider
        self.turnNoteProvider = turnNoteProvider
        self.groundingBudgetProvider = groundingBudgetProvider
        self.plainRouteProvider = plainRouteProvider
        self.excludedKinds = excludedKinds
        self.postToolAnswerPolicy = postToolAnswerPolicy
    }

    /// Fixed tool list — convenience for tests and simple callers.
    public init(
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        provider: any InferenceProvider,
        tools: [any AgentTool],
        topK: Int = 5,
        maxIterations: Int = 5
    ) {
        self.init(
            store: store, embedder: embedder, provider: provider,
            toolsProvider: { tools }, topK: topK, maxIterations: maxIterations
        )
    }

    /// History-free entry points (tests, simple callers): same turn, no replay.
    /// Both forward UP to the real (history) implementation — the protocol's
    /// one-way defaults would forward DOWN to the plain variant and bypass it.
    public func answerStreaming(
        _ question: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, history: [], onActivity: { _ in })
    }

    public func answerStreaming(
        _ question: String,
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, history: [], onActivity: onActivity)
    }

    /// The honest line M1K3 gives when Cool Head defers a heavy turn (critical
    /// thermal). Warm, brief, and truthful — never a silent non-answer.
    static let coolHeadDeferralMessage =
        "My \(HostPlatform.noun)'s gone properly warm, so I'm easing off the heavy thinking for a "
            + "moment to let it cool down. Give it a minute and ask me again."

    public func answerStreaming(
        _ question: String,
        history: [ChatTurn],
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, images: [], history: history, onActivity: onActivity)
    }

    /// What a turn says when its brain can't take the images attached (2026-10-19). Brain at Home answers through
    /// the ReAct floor, a text prompt with no image in it: the phone showed the thumbnail and the Mac's brain
    /// answered as if it had looked. Same promise as Mini's decline (`AFMToolPrompt.cannotShowImageReply`).
    static func imageNotCarriedReply(imageCount: Int, brainName: String) -> String {
        let name = brainName.trimmingCharacters(in: .whitespacesAndNewlines)
        let brain = name.isEmpty ? "This brain" : name
        let (images, them) = imageCount == 1 ? ("the image", "it") : ("the \(imageCount) images", "them")
        return "\(brain) can't take images yet, so I haven't seen \(images) you attached "
            + "and won't guess at what's in \(them)."
    }

    public func answerStreaming(
        _ question: String,
        images: [ImageAttachment],
        history: [ChatTurn],
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        // Cool Head at minimal (critical thermal, opt-in ON): skip the whole heavy
        // path — no embed, no retrieval, no decode — and answer honestly instead of
        // piling onto a throttling Mac. The caller (ChatSession) has already recorded
        // the user's turn, so this just fills the assistant bubble; the transcript is
        // intact. Default path (provider nil/false) is byte-identical.
        if defersHeavyGenerationProvider?() == true {
            let message = Self.coolHeadDeferralMessage
            let stream = AsyncStream<String> { continuation in
                continuation.yield(message)
                continuation.finish()
            }
            return (sources: [], stream: stream)
        }

        // Only AFM returns false today (MLX/HomeBrain hardcode true). If another
        // backend tightens isAvailable, its message should come from the provider.
        if !provider.isAvailable {
            throw InferenceError.providerUnavailable(
                "Mini is temporarily unavailable — Apple Intelligence is not ready. "
                    + "Try switching to another brain in Settings."
            )
        }

        // Images ride only the native tool session (LocalAgent.run): a brain without tool calls runs the ReAct
        // floor, which drops them. Say so before anything is embedded or generated, never answer unseen. After
        // the availability throw, so an unready Mini still reads as unavailable.
        if !images.isEmpty, (provider as? ToolCallingProvider)?.supportsToolCalls != true {
            Self.log.notice("image turn declined: \(images.count) image(s), the provider can't carry them")
            let message = Self.imageNotCarriedReply(imageCount: images.count, brainName: brainNameProvider())
            let stream = AsyncStream<String> { continuation in
                continuation.yield(message)
                continuation.finish()
            }
            return (sources: [], stream: stream)
        }

        // Cool Head's line (#697), on the activity channel and nowhere else. After the three gates
        // above, so a deferred, unavailable or declined turn leaves the line unread (the next send
        // overwrites it); before the phase timeline, so the caption is up before retrieval.
        if let note = turnNoteProvider?(), !note.isEmpty {
            onActivity(.note(note))
        }

        // Pre-generation phase instrument: the 2026-08-10 eval found 177s of
        // total log silence before a turn's first model call — "turn start:"
        // only fires after retrieval, so a blocked embed was invisible. One
        // line per turn now names where the pre-gen time went.
        let phaseClock = ContinuousClock()
        var phases = TurnPhaseTimeline()
        phases.started(at: phaseClock.now)
        // Stale tool hits from an aborted prior turn must not leak in.
        _ = sourceCollector?.drain()
        // Self-query router (prompt-hardening v2): a question about M1K3
        // itself never touches retrieval — nothing embedded, nothing injected
        // — and the corpus-reaching tools are withheld from the turn below.
        // The persona's SELF rule states this policy; the gate enforces it in code.
        let isSelfQuery = SelfQueryGate.isSelfQuery(question)
        var chunks: [ChunkHit]
        var memories: [ChunkHit]
        if isSelfQuery {
            Self.log.notice("self-query gate: retrieval skipped, corpus tools withheld")
            (chunks, memories) = ([], [])
        } else {
            onActivity(.retrieving)
            let queryVector = try await embedder.embedQuery(question)
            phases.embedded(at: phaseClock.now)
            // Two-lane retrieval: documents and memories get SEPARATE top-K budgets
            // so the larger document corpus can't crowd short memory facts out of a
            // single ranking (the open-chat recall miss — M1K3 forgot the user's
            // own city when the query leaned even slightly documentary).
            let retrieved = try store.searchGrounding(
                query: question, queryVector: queryVector,
                documentLimit: topK, memoryLimit: memoryTopK,
                excludedKinds: excludedKinds
            )
            // Gate on relevance: each lane ALWAYS returns something, even for "what
            // model are you?" — weak hits pollute the prompt and derail small
            // models. Below threshold nothing is injected; the model can still
            // retrieve on its own terms via search_knowledge. Memory hits clear
            // their own (lower) bar and feed a separate uncited prompt block.
            // Floors follow the ACTIVE embedder's cone (hashing fallback ≠
            // instructed qwen3) — resolved per turn because the swappable
            // façade can flip embedders at runtime.
            (chunks, memories) = GroundingGate.partition(
                retrieved, floors: .forFingerprint(embedder.fingerprint)
            )
            // The gate log speaks BEFORE the wiring filter below: its kept/gated
            // verdict is the relevance floor's alone, so a floor tuned from the
            // log never absorbs a #286 drop (review 12 on #288).
            Self.logGateDecision(retrieved: retrieved, kept: chunks + memories)
            // #670: the hashing cone never reaches a whole-document chunk on a keyword
            // question; one strict-AND BM25 chunk stands in when no document cleared.
            // An extra, never a reason to fail the turn: a store error answers ungrounded.
            if chunks.isEmpty {
                do {
                    if let keyword = try HashingKeywordLane.admit(
                        store: store, query: question, fingerprint: embedder.fingerprint,
                        excludedKinds: excludedKinds
                    ) {
                        Self.log.notice("hashing keyword lane: 1 document chunk admitted")
                        chunks = [keyword]
                    }
                } catch {
                    Self.log.notice("hashing keyword lane failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            // #286's wiring-shaped self notes never reach the prompt, so they
            // must not spend the grounding budget either (review 4 on #288: a
            // wiring hit outranking a real memory ate the last unit of a tight
            // budget, then rendered as nothing). Filtered at the source; the
            // two read sites below re-apply the same filter for their other
            // callers. Dropped hits get their own count line — ids and titles
            // stay out of the log for the reason `logGateDecision` gives.
            let usable = Self.usableMemories(memories)
            if usable.count < memories.count {
                Self.log.notice(
                    "memory hits dropped as wiring-shaped self notes: \(memories.count - usable.count, privacy: .public)"
                )
            }
            memories = usable
            phases.retrieved(at: phaseClock.now)
        }
        // Grounding-size safety cap (2026-07-20): both lanes above are injected
        // VERBATIM and UNTRUNCATED downstream (groundingBody). On gemma-4-12B
        // ("Big"), PR #65's prompt-size instrument measured the grounded-Q worst
        // case at 2998 of a 3000-token reserve — 2 tokens of headroom before
        // `RotatingKVCache(8192)` silently rotates the persona/grounding head out
        // mid-turn with NO error. GroundingBudget caps at the source instead —
        // on EVERY tier. When this turn's provider has no tokenizer (AFM/Mini)
        // the cap estimates rather than standing down: the exemption this
        // comment used to describe ("AFM/Mini self-manage their own windows")
        // was the 2026-08-03 bug, and Mini's window is the smallest of the lot
        // at 4096 tokens.
        let beforeCapChunks = chunks
        let beforeCapMemories = memories
        let countTokens: (String) async -> Int? = { [provider] text in
            await (provider as? TokenCounting)?.tokenCount(text)
        }
        let groundingTokenBudget = groundingBudgetProvider()
        (chunks, memories) = await GroundingBudget.fit(
            chunks: chunks, memories: memories,
            tokenBudget: groundingTokenBudget,
            countTokens: countTokens
        )
        // Marked BEFORE the diagnostic block below — its extra tokenizer
        // passes are logging overhead, and folding them into "cap Xms" would
        // make the instrument distort the thing it measures.
        phases.capped(at: phaseClock.now)
        if chunks != beforeCapChunks || memories != beforeCapMemories {
            // Only pay for the extra tokenizer passes when the cap actually did
            // something — the common case (nothing dropped, or no tokenizer at
            // all) never recomputes totals just to decide whether to log.
            let beforeTokens = await GroundingBudget.totalTokens(
                chunks: beforeCapChunks, memories: beforeCapMemories, countTokens: countTokens
            )
            let afterTokens = await GroundingBudget.totalTokens(
                chunks: chunks, memories: memories, countTokens: countTokens
            )
            Self.log.notice(
                """
                grounding cap: units \(beforeCapChunks.count + beforeCapMemories.count)\
                →\(chunks.count + memories.count), tokens \(beforeTokens)→\(afterTokens)
                """
            )
        }
        // Snapshot as `let` for the closure below — `chunks`/`memories` are
        // `var` only so the cap above could reassign them; a `var` capture in
        // a Task closure is a Swift 6 sending-risk error even though nothing
        // mutates them again after this point.
        let cappedChunks = chunks
        let cappedMemories = memories
        // Resolve the tool list once per turn; the routing rules must match
        // what's actually callable (no advertising a disabled web_search).
        // On a self-query turn the retrieval tools are withheld entirely —
        // the model cannot call what it is never offered.
        let tools = isSelfQuery
            ? toolsProvider().filter { !SelfQueryGate.withheldToolNames.contains($0.name) }
            : toolsProvider()

        // The tool router (Mini, flagged): a turn it reads as plain chat skips the
        // palette and the agent loop for one streamed generation. Images always
        // take the agent turn, which is where the vision path lives.
        let plainRoute = images.isEmpty && !tools.isEmpty ? plainRouteProvider?() : nil
        let gate = plainRoute.map { $0.decide(question) }
        // #622: a turn about what was said in THIS chat is the replay's to answer. The gate can't
        // tell "earlier" here from "earlier, another day", and a tool's output put another chat's
        // facts in the answer. Only with history: on a fresh chat there is nothing to point back at.
        let pointsBack = gate?.verdict == .tools && !history.isEmpty
            && (gate?.probability ?? 1) < ToolNeedRouter.pointsBackCeiling
            && ToolNeedRouter.pointsBackInChat(question)
        let decision = pointsBack
            ? gate.map { ToolNeedRouter.Decision(verdict: .chat, probability: $0.probability) }
            : gate
        if let decision {
            let score = decision.probability.map { String(format: "%.3f", $0) } ?? "none"
            let verdict = decision.verdict == .chat ? "chat" : "tools"
            let why = pointsBack ? " (points back in this chat)" : ""
            Self.log.notice(
                "tool router: \(verdict, privacy: .public) p=\(score, privacy: .public)\(why, privacy: .public)"
            )
        }
        let routeInstructions = plainRoute?.instructions
        let routesPlain = decision?.verdict == .chat
        // A chat verdict carries no knowledge excerpts (#430), whichever lane ends up
        // answering — the agent turn a blank plain turn hands over to included — and the
        // sources below list none. A tools verdict keeps them everywhere, its plain fallbacks
        // too: the eval measured the chat route only. (Still loose, and older: a dispatched
        // tool's answer reads only the tool's result, yet its sources list the excerpts.)
        let turnChunks = routesPlain ? [] : cappedChunks
        // Router-invoked tools: on a tools verdict, a picker may name ONE read-only
        // tool that the app runs itself (ToolDispatch); nil keeps the agent turn.
        let picker = decision?.verdict == .tools ? plainRoute?.pick : nil

        // One reasoning decision for the WHOLE turn (#555): the plain route and the
        // post-tool synthesis generate through `provider.generateStreaming`, which
        // read only the construction-time flag (thinking ON in the app) — so on Auto
        // they thought to the 4,096-token cap while the tool session answered fast.
        // Same inputs as the agent path's own decision, so the two agree.
        let turnThinking = ThinkingPolicy.shouldThink(
            question: question,
            hasGroundedKnowledge: Self.hasGroundedKnowledge(chunks: turnChunks, memories: cappedMemories),
            mode: thinkingModeProvider(),
            fastByDefault: fastThinkingProvider()
        )
        // The turn writes to `inner`; the consumer reads `stream`, a forwarder that marks the first chunk
        // (`turn first token:` — the one number a waiting person feels, unlogged until 2026-10-25). The
        // hand-off is marked here, before the forwarder exists, so the snapshot it logs against is final.
        let (inner, continuation) = AsyncStream<String>.makeStream()
        let turnTask = Task {
            await InferenceIntent.withThinking(turnThinking) {
                if routesPlain {
                    let answered = await runPlainTurn(
                        question: question, chunks: turnChunks, memories: cappedMemories,
                        history: history, instructions: routeInstructions,
                        onActivity: onActivity, continuation: continuation
                    )
                    // Answered, or the consumer went away: either way, no agent turn.
                    if answered || Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    Self.log.notice("plain turn came back empty — the agent turn answers instead")
                }
                var agentTools = tools
                if let picker { // a tools verdict: never after a plain turn
                    let outcome = await runDispatchedTurn(
                        question: question, picker: picker, staysLocal: plainRoute?.staysLocal,
                        tools: tools, chunks: turnChunks,
                        memories: cappedMemories, history: history, instructions: routeInstructions,
                        onActivity: onActivity, continuation: continuation
                    )
                    guard case let .agent(palette) = outcome, !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    agentTools = palette
                }
                await runAgentTurn(
                    question: question,
                    images: images,
                    chunks: turnChunks,
                    memories: cappedMemories,
                    history: history,
                    tools: agentTools,
                    thinkingEnabled: turnThinking,
                    onActivity: onActivity,
                    continuation: continuation
                )
            }
        }
        phases.handedOff(at: phaseClock.now)
        if let phaseLine = phases.summary(gate: isSelfQuery ? .selfQuery : .normal) {
            Self.log.notice("\(phaseLine, privacy: .public)")
        }
        let handedOff = phases
        let stream = AsyncStream<String> { outer in
            let forward = Task {
                var first = true
                for await piece in inner {
                    if first, TurnPhaseTimeline.isFirstRealToken(piece) {
                        first = false
                        if let line = handedOff.firstTokenSummary(at: phaseClock.now) {
                            Self.log.notice("\(line, privacy: .public)")
                        }
                    }
                    outer.yield(piece)
                }
                outer.finish()
            }
            // The turn's Task is NOT a child of the stream's consumer, so the
            // consumer cancelling (user sends a new message mid-loop, voice
            // mode bails) would otherwise leave the agent loop running to the
            // iteration cap. Terminating the stream cancels the turn.
            outer.onTermination = { _ in
                turnTask.cancel()
                forward.cancel()
            }
        }
        // Memory hits ride along as sources so the UI shows their provenance.
        return (turnChunks + cappedMemories, stream)
    }

    /// Grounding for the think-phase decision counts BOTH retrieval lanes: a
    /// turn grounded only by a memory hit (0 doc chunks) is still a grounded
    /// answer and earns CoT on the heavy tiers, same as a document hit.
    static func hasGroundedKnowledge(chunks: [ChunkHit], memories: [ChunkHit]) -> Bool {
        !chunks.isEmpty || !usableMemories(memories).isEmpty
    }

    /// The memory hits that will actually render in WHAT I KNOW ABOUT YOU —
    /// #286's wiring-shaped self notes removed. ONE filter for both the
    /// think-phase decision and the block, so the two cannot disagree (review
    /// 3 on #288: a wiring-only hit reported "grounded" for an empty block).
    static func usableMemories(_ memories: [ChunkHit]) -> [ChunkHit] {
        memories.filter { !SelfNoteClassifier.isWiringNote(title: $0.itemTitle, text: $0.content) }
    }

    /// Whether the kept document-lane chunks hold one of the USER's own documents, the premise
    /// of `ToolDispatch.documentCorrected`. An imported conversation (#711) shares the lane but
    /// is another assistant's old answer on any topic, so it never turns a lookup into a plain turn.
    static func keptUserDocument(_ chunks: [ChunkHit]) -> Bool {
        chunks.contains { $0.kind != .conversation }
    }

    /// This turn's cut, in characters of open reasoning: a net above the brain's own budget when it forces its
    /// close (asked through the façade each turn, so a hot-swap follows), else `thinkingBudget`.
    private var thinkingCut: Int {
        guard let tokens = (provider as? ThinkBudgetForcing)?.forcedThinkingTokens else { return thinkingBudget }
        return ThinkBudget.characterCap(forTokens: tokens)
    }

    /// One plain-chat turn into `continuation`: the turn's context, history and
    /// grounding with tool-free rules, one streamed generation. Returns false when
    /// nothing came back (AFM turns a guardrail or overflow into an empty stream),
    /// so the caller can hand the turn to the agent instead of a blank bubble.
    private func runPlainTurn(
        question: String,
        chunks: [ChunkHit],
        memories: [ChunkHit],
        history: [ChatTurn],
        instructions: String?,
        observation: String? = nil,
        onActivity: @escaping @Sendable (ResponderActivity) -> Void,
        continuation: AsyncStream<String>.Continuation
    ) async -> Bool {
        onActivity(.thinking(iteration: 0))
        // Read once: the anatomy line below must describe the window this prompt was built with.
        let historyBudget = historyBudgetProvider()
        let prompt = if let observation {
            // A dispatched turn: the date (not the identity line) and the age clause.
            Self.dispatchTurnPrompt(
                question: question,
                preamble: ([PromptContext.line(now: Date(), brainName: "")] + turnClauses())
                    .compactMap { $0 }.joined(separator: "\n\n"),
                history: history, historyBudget: historyBudget, observation: observation
            )
        } else {
            // No date line (#428/#349): on small talk it was the one concrete thing in the
            // prompt, and Mini opened on it or pinned it on the user. A time ask routes to
            // `datetime`, and the persona keeps the month and year.
            Self.plainTurnPrompt(
                question: question,
                contextPreamble: ([PromptContext.identity(brainName: brainNameProvider())] + turnClauses())
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"),
                chunks: chunks, memories: memories,
                history: history, historyBudget: historyBudget,
                ambient: browserContextProvider?()?.render(), todos: todoContextProvider?()
            )
        }
        // The cut rides the anatomy line, so a launch shows which one this turn got (8,192 behind a forcing brain).
        let thinkingBudget = thinkingCut
        let anatomy = Self.promptAnatomy(prompt: prompt, history: history, budget: historyBudget)
        Self.log.notice("\(anatomy, privacy: .public) · cut \(thinkingBudget)")
        let generate: @Sendable () async -> Bool = { [provider] in
            var answer = PlainTurnStream()
            for await chunk in provider.generateStreaming(prompt: prompt) {
                if Task.isCancelled { break }
                // Cumulative out, whatever came in: the consumer folds snapshots.
                guard let clean = answer.ingest(chunk) else { continue }
                continuation.yield(clean)
                // The thinking cap: leaving the loop ends the stream, whose termination
                // cancels the generation, and the turn answers straight below.
                if answer.thinkingPastBudget(thinkingBudget) {
                    Self.log.notice("plain turn thinking passed its budget (\(thinkingBudget) chars) — cutting it")
                    break
                }
            }
            // Reasoning alone is no answer (2026-10-17): a think phase cut at the token cap
            // left an empty bubble, and no fallback ran because it had streamed. Answer once
            // more, thinking off, after the shown reasoning — even on Always-think, whose
            // think phase has just been spent. Nothing back from that: the caller's fallback.
            // Cancelled: the consumer has gone, so no fallback either (PR review).
            if Task.isCancelled { return true }
            guard answer.thoughtWithoutAnswering else { return answer.hasAnswer }
            Self.log.notice("plain turn thought to the cap without answering — answering straight")
            // Closed now, not with the retry's first piece: an empty retry hands over to the
            // agent, whose answer must land after `</think>`, not inside the open reasoning.
            let closed = answer.closedReasoning
            continuation.yield(closed)
            return await InferenceIntent.withThinking(false) {
                var retry = PlainTurnStream()
                for await chunk in provider.generateStreaming(prompt: prompt) {
                    if Task.isCancelled { break }
                    guard let clean = retry.ingest(chunk) else { continue }
                    continuation.yield(closed + clean)
                }
                return retry.hasAnswer || Task.isCancelled
            }
        }
        // `InferenceIntent` warns against an override on the chat provider: AFM's
        // PrewarmSlot drops a warm session whose instructions don't match. Crossed on
        // purpose (ADR 0008): the route speaks in the agent turns' persona, and the
        // re-arm below restores the slot. The cost is measured (~0.7 s of first word).
        let answered = if let instructions {
            await InferenceIntent.withInstructions(instructions) { await generate() }
        } else {
            await generate()
        }
        // LocalAgent re-arms the next turn in its defer; this turn never ran it. On an
        // empty stream the agent turn takes over and re-arms itself: one re-arm, not two
        // back to back (the AFM daemon has fallen over under rapid prewarms).
        if answered {
            (provider as? TurnWarmable)?.prepareForNextTurn(promptPrefix: nil)
        }
        return answered
    }

    /// The plain turn's prompt: the per-turn context line, the history replay and
    /// the turn's grounding sections, tool-free rules, then the question.
    static func plainTurnPrompt(
        question: String, contextPreamble: String, chunks: [ChunkHit], memories: [ChunkHit],
        history: [ChatTurn], historyBudget: HistoryWindow.Budget, ambient: String?, todos: String?,
        now: Date = Date()
    ) -> String {
        let sections = groundingSections(
            chunks: chunks, memories: memories, toolNames: [], now: now, ambient: ambient, todos: todos
        )
        // No excerpts: no "No stored knowledge matched" head either (#430). Mini quoted it
        // back, and a "found nothing" beside a known fact is how it came to disown one.
        // The head is always `groundingSections`' first element.
        let grounding = chunks.isEmpty ? Array(sections.dropFirst()) : sections
        let body = (grounding + [plainRules]).joined(separator: "\n\n")
        let grounded = HistoryWindow.render(history, budget: historyBudget)
            .map { "\($0)\n\(replayFraming)\n\n\(body)" } ?? body
        return [contextPreamble, grounded, "USER: \(question)"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// One log line splitting a plain or dispatched prompt into the history replay and the
    /// rest (2026-10-16): the voice rig read ~1,900 tokens past Big's persona seed per turn,
    /// and whether a history cache or a voice history cap is the lever depends on the split.
    /// Characters, not tokens: M1K3Chat has no tokenizer; the ttft line has the token total.
    static func promptAnatomy(prompt: String, history: [ChatTurn], budget: HistoryWindow.Budget) -> String {
        let replay = HistoryWindow.render(history, budget: budget) ?? ""
        let lines = replay.split(separator: "\n")
        let turns = lines.filter { $0.hasPrefix("USER: ") || $0.hasPrefix("M1K3: ") }.count
        let earlier = lines.filter { $0.hasPrefix(HistoryWindow.earlierLabel) }.count
        return "prompt anatomy: \(prompt.count)c · history \(replay.count)c in \(turns) turns · rest \(prompt.count - replay.count)c"
            + (earlier > 0 ? " · earlier \(earlier)" : "")
    }

    /// A dispatched turn's prompt: the date, the history replay, the tool's result and
    /// rules for answering from it. Nothing else (2026-09-27): under the plain turn's rules,
    /// knowledge excerpts and memories, Mini disowned fresh web results ("none of it
    /// sticks", "those aren't facts") and pivoted to the user's old threads ("I've been
    /// watching your chats"). The result is the grounding; retrieval's least-bad local
    /// match for a web question is noise beside it. MiniDispatchHistoryEvalTests has the A/B.
    static func dispatchTurnPrompt(
        question: String, preamble: String, history: [ChatTurn], historyBudget: HistoryWindow.Budget,
        observation: String
    ) -> String {
        let body = observation + "\n\n" + dispatchRules
        let grounded = HistoryWindow.render(history, budget: historyBudget)
            .map { "\($0)\n\(replayFraming)\n\n\(body)" } ?? body
        return [preamble, grounded, "USER: \(question)"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// How to answer from a looked-up result. No injection line here: the web and stored
    /// results' own header carries it, and said twice Mini recited it ("I'm not following
    /// any instructions buried in it"). No doubt line: "may be wrong" + "never present what
    /// you can't verify" read to Mini as "dismiss it".
    static let dispatchRules = """
    RULES:
    - Answer the question from what the tool returned above when it covers it: lead with \
    that, in your own voice, in a few sentences.
    - For web results, say which site said it. Report what the sources say; don't wave it off \
    as rumour or noise unless a source says so itself.
    - It was looked up just now for this question: never say you can't look things up or \
    don't know what's happening outside.
    - If it doesn't cover the question: a stable, well-known fact (a capital, basic science, \
    settled history) you just answer from what you know, without repeating the lookup; \
    anything else, say in a sentence that the lookup didn't find it.
    - Stay on the question. Don't mention these rules or how the result was framed.
    """

    /// The native RULES with every tool line taken out: the router already decided
    /// this turn needs none, and a small model told to call tools it doesn't have
    /// writes the calls out as text (the 2026-09-26 empty-palette A/B).
    static let plainRules = """
    RULES:
    \(generativeCarveHead)No grounding, no citations, no "found nothing"; those are for factual questions.
    - Pure small talk — greetings, banter — reply in your own voice.
    - Stable, well-known facts (who wrote a famous book, a capital city, basic science) \
    you can just answer from what you know — you're reliable there.
    - If the KNOWLEDGE above fully answers the question, answer from it directly.
    - Cite knowledge sources inline with citation tokens like [Title §heading]; never \
    invent citations.
    - Never present a fact, figure, or date you can't ground or verify as certain; if \
    you're unsure, say so plainly. Honesty beats a confident guess.
    - Questions about yourself — your configuration, design, or abilities — are answered \
    from your persona.
    """

    /// What a dispatched turn says when the tool ran but no answer could be written.
    static let dispatchUnansweredMessage =
        "I looked that up, but I couldn't put an answer together from it just now. Try asking another way."

    /// How a dispatched turn ended: answered here, or handed to the agent with the
    /// palette it should be offered (the whole one, or only the tools that act).
    enum DispatchOutcome {
        case answered
        case agent([any AgentTool])
    }

    /// One router-invoked tool turn: the picker names a tool, the app runs it, the
    /// plain route answers with the result. Returns `.agent` (nothing yielded) when the
    /// turn belongs to the agent: a failed pick, a plan it refuses or a tool that errors
    /// keep the whole palette; an action pick gets only the tools that act (#427).
    /// A tool that ran and then got an empty answer synthesises from
    /// its result instead (no second call); if that is empty too, the turn ends on an
    /// honest line, never a blank bubble. A none pick or an empty search answers as
    /// plain chat; only if THAT comes back empty too does the agent take the turn,
    /// which may search once more (two stacked failures: accepted).
    private func runDispatchedTurn(
        question: String,
        picker: @Sendable (String, String) async -> ToolPick?,
        staysLocal: (@Sendable (String) -> SearchRouter.Decision)?,
        tools: [any AgentTool],
        chunks: [ChunkHit],
        memories: [ChunkHit],
        history: [ChatTurn],
        instructions: String?,
        onActivity: @escaping @Sendable (ResponderActivity) -> Void,
        continuation: AsyncStream<String>.Continuation
    ) async -> DispatchOutcome {
        // A plain turn that came back empty hands over to the agent, as the chat route does.
        let plain: @Sendable () async -> DispatchOutcome = { [self] in
            await runPlainTurn(
                question: question, chunks: chunks, memories: memories, history: history,
                instructions: instructions, onActivity: onActivity, continuation: continuation
            ) ? .answered : .agent(tools)
        }
        guard let picked = await picker(question, ToolDispatch.menu(palette: tools)) else {
            Self.log.notice("tool dispatch: no pick — the agent turn answers")
            return .agent(tools)
        }
        // A reference lookup about now goes to the web (2026-10-10: "this year" picked lookup_fact).
        // An "open the website" ask read the page aloud (#622): opening is an action.
        // A question about what the user decided went to Wikipedia (2026-10-20): it goes to their knowledge.
        let corrected = ToolDispatch.corrected(picked, palette: tools, question: question)
        // A reference lookup the user's own documents answer reads them instead (2026-10-26).
        var pick = ToolDispatch.documentCorrected(corrected, documentsKept: Self.keptUserDocument(chunks))
        if pick != corrected {
            Self.log.notice("tool dispatch: lookup_fact, but kept chunks answer — a plain turn reads them")
            return await plain()
        }
        // The search head (#713, `toolSearchHead`): asked only when the pick reads the web and the user
        // didn't ask for the web in words, so it never adds a call and never overrides an explicit ask.
        // A local verdict takes the web reads out; nothing left falls to the none branch.
        if let staysLocal, ToolDispatch.vetoable(pick, question: question) {
            let decision = staysLocal(question)
            let score = decision.probability.map { String(format: "%.3f", $0) } ?? "none"
            let vetoed = ToolDispatch.searchCorrected(pick, staysLocal: decision.verdict == .local)
            if vetoed != pick {
                // Name the web reads that left, not the head: a chain's web link can be its tail.
                let dropped = ([pick] + pick.then).map(\.tool).filter(ToolDispatch.webSourced.contains)
                    .joined(separator: ",")
                Self.log.notice(
                    "search head: local p=\(score, privacy: .public) — \(dropped, privacy: .public) vetoed"
                )
                ToolRouterWiring.pickRecorder?.record(.searchVeto)
                pick = vetoed
            } else {
                Self.log.notice("search head: web p=\(score, privacy: .public)")
            }
        }
        if pick.tool == ToolPick.noTool {
            Self.log.notice("tool dispatch: none — a plain turn answers")
            return await plain()
        }
        // #427: the read-only tools are this path's job. Offered them as well, Mini's native
        // session overflowed its window (4,282 tokens on 375). Nothing on offer acts (MCP):
        // a plain turn, since an empty palette through the agent prompt writes junk.
        // Known narrowing: a same-turn read-then-act ("check my calendar, then script it")
        // can't read here; a big one goes through delegate_deep, whose agent has the reads.
        if pick.tool == ToolPick.action {
            let acting = ToolDispatch.actionPalette(tools)
            guard !acting.isEmpty else {
                Self.log.notice("tool dispatch: action, but nothing on offer acts — a plain turn answers")
                return await plain()
            }
            Self.log.notice("tool dispatch: action — the agent gets \(acting.count, privacy: .public) acting tool(s)")
            return .agent(acting)
        }
        // A tool this turn doesn't offer (MCP carries no device senses): the agent has no
        // such tool either, and on Mini its native session can overflow the window. A plain
        // turn answers honestly in one generation (374 over MCP).
        if ToolDispatch.dispatchable.contains(pick.tool), !tools.contains(where: { $0.name == pick.tool }) {
            Self.log.notice("tool dispatch: \(pick.tool, privacy: .public) is not on offer — a plain turn answers")
            return await plain()
        }
        guard let plan = ToolDispatch.plan(pick, palette: tools, question: question) else {
            Self.log.notice("tool dispatch: \(pick.tool, privacy: .public) stays with the agent")
            return .agent(tools)
        }
        // A chain (2026-10-07): the pick, then any further read-only tool the turn named, run
        // in order. Each that ran with something to say feeds the one answer; a link the app
        // can't plan is skipped, never handed to the agent once the head has a plan.
        let plans = [plan] + ToolDispatch.chain(pick, palette: tools).dropFirst().compactMap {
            ToolDispatch.plan($0, palette: tools, question: question)
        }
        var ran: [(plan: ToolDispatch.Plan, output: String)] = []
        var failures = 0
        var failedNames: [String] = []
        for step in plans {
            if Task.isCancelled { return .answered }
            onActivity(.usingTool(name: step.tool.name, argument: step.input.values.first ?? ""))
            guard let output = try? await step.tool.execute(input: step.input).output, !output.hasPrefix("Error") else {
                // A cancel surfaces here as a nil output: it is no tool failure.
                if Task.isCancelled { return .answered }
                Self.log.notice("tool dispatch: \(step.tool.name, privacy: .public) failed")
                failures += 1
                failedNames.append(step.tool.name)
                continue
            }
            if ToolDispatch.isEmptyResult(output) {
                Self.log.notice("tool dispatch: \(step.tool.name, privacy: .public) found nothing")
                continue
            }
            Self.log.notice("tool dispatch: \(step.tool.name, privacy: .public) ran, \(output.count, privacy: .public) chars")
            ran.append((step, output))
        }
        // A cancel during the last link: no answer for a consumer that has gone (#510 review).
        // Results that already ran are dropped with it: every link is a read, nothing to undo.
        if Task.isCancelled { return .answered }
        // Nothing ran: every tool failed → the agent turn; none failed but none found
        // anything → a plain turn (a "found nothing" is not evidence). Something ran: answer
        // from it, naming any link that failed (a failed head with a second link that ran
        // answers from the second: DispatchChainTests.partialFailure).
        guard !ran.isEmpty else {
            if failures == 0 {
                Self.log.notice("tool dispatch: nothing found — a plain turn answers")
                return await plain()
            }
            Self.log.notice("tool dispatch: no tool ran — the agent turn answers")
            return .agent(tools)
        }
        // One budget for the turn, shared across the results: the short ones whole, the
        // rest to the long one. A link that failed is named, so the answer doesn't invent
        // its half (a chain only: a lone failure went to the agent above).
        // Measured on what the model reads (`promptText`), as `observationBlock` cuts it: the same text.
        let shares = ToolDispatch.shares(ran.map {
            ToolDispatch.promptText(tool: $0.plan.tool.name, output: $0.output).count
        })
        let blocks = zip(ran, shares).map { result, share in
            ToolDispatch.observationBlock(tool: result.plan.tool.name, output: result.output, budget: share)
        }
        let observation = (blocks + failedNames.map { "\($0) couldn't be read just now." })
            .joined(separator: "\n\n")
        let answered = await runPlainTurn(
            question: question, chunks: chunks, memories: memories, history: history,
            instructions: instructions, observation: observation,
            onActivity: onActivity, continuation: continuation
        )
        let steps = ran.enumerated().map { index, result in
            ReasoningStep(
                iteration: index + 1, thought: "",
                action: "\(result.plan.tool.name)(\(result.plan.input.values.first ?? ""))", observation: result.output
            )
        }
        if !answered {
            // A guardrail after a SUCCESSFUL tool call: the agent's own synthesis step with
            // the result in hand, never the whole loop again (it would re-run the tool over
            // the network; PR #420 review).
            if Task.isCancelled { return .answered }
            Self.log.notice("tool dispatch: empty answer after \(ran.count, privacy: .public) tool(s) — synthesising from the results")
            // The result keeps its framed header (the injection guard) and the age clause
            // rides along: this path once handed the raw web text over bare (PR #424 review).
            let contextLine = ([PromptContext.line(now: Date(), brainName: brainNameProvider())] + turnClauses())
                .compactMap { $0 }.joined(separator: "\n\n")
            let framed = zip(steps, blocks).map { step, block in
                ReasoningStep(iteration: step.iteration, thought: "", action: step.action, observation: block)
            }
            let synthesised = await streamFallback(
                question: question, chunks: chunks, contextLine: contextLine, gathered: framed, into: continuation
            )
            // Guardrail twice on the same fetched text: never a dead bubble (PR #420 review).
            if !synthesised, !Task.isCancelled {
                continuation.yield(Self.dispatchUnansweredMessage)
            }
        }
        // The same deterministic provenance the agent turn appends.
        let trace = AgentResult(
            conclusion: "", toolsUsed: ran.map { $0.plan.tool.name }, iterations: steps.count, reasoningTrace: steps
        )
        let tail = Self.webSourcesBlock(for: trace) + Self.factSourcesBlock(for: trace)
        if !tail.isEmpty { continuation.yield(tail) }
        return .answered
    }

    /// The per-turn policy clauses every prompt carries: the age band and what can
    /// leave the device (#482). nil entries are dropped by the callers' compactMap.
    private func turnClauses() -> [String?] {
        // The egress answer as this brain's persona reads it: pocket's starts at the facts
        // (`EgressDisclosure.adapted`).
        let variant = (provider as? ToolCallingProvider)?.personaVariant ?? .standard
        let egress = egressClauseProvider().map { EgressDisclosure.adapted($0, for: variant) }
        return [ageClauseProvider(), egress, styleClauseProvider(), voiceClauseProvider()]
    }

    /// One full agent turn into `continuation`: run the loop (conclusion tail
    /// streams live), then the web-sources tail, with the plain-RAG fallback
    /// on throw or empty.
    private func runAgentTurn(
        question: String,
        images: [ImageAttachment],
        chunks: [ChunkHit],
        memories: [ChunkHit],
        history: [ChatTurn],
        tools: [any AgentTool],
        thinkingEnabled: Bool,
        onActivity: @escaping @Sendable (ResponderActivity) -> Void,
        continuation: AsyncStream<String>.Continuation
    ) async {
        // Match the loop LocalAgent will actually run (same capability check),
        // so the native path never sees the ReAct format scaffold.
        let style: Self.PromptStyle =
            (provider as? ToolCallingProvider)?.supportsToolCalls == true ? .native : .react
        // The per-turn truth: today's precise date + which brain is answering.
        // Prepended here (not inside `grounding`, which stays pure/testable) so it
        // rides the variable grounding, never the cached persona prefix.
        let contextLine = PromptContext.line(now: Date(), brainName: brainNameProvider())
        let contextPreamble = ([contextLine] + turnClauses()).compactMap { $0 }.joined(separator: "\n\n")
        let toolNames = Set(tools.map(\.name))
        let historyBudget = historyBudgetProvider().reservingImages(images.count)
        let ambient = browserContextProvider?()?.render()
        let todos = todoContextProvider?()
        // The ReAct floor takes its RULES apart from the turn and puts them in its
        // stable head (the prefix AFM prewarms); the native loop keeps them where
        // they have always been, after the grounding.
        let grounding: String
        let standing: String?
        // Where the grounding stops being stable across turns (the context line + the replay), for the
        // tool session's cross-turn tail cut; nil on the ReAct floor, which has no KV tail.
        let stableContextChars: Int?
        switch style {
        case .react:
            let parts = Self.reactParts(
                chunks: chunks, memories: memories, toolNames: toolNames, history: history,
                historyBudget: historyBudget, ambient: ambient, todos: todos
            )
            grounding = contextPreamble + "\n\n" + parts.context
            standing = parts.standing
            stableContextChars = nil
        case .native:
            let native = Self.groundingWithStablePrefix(
                chunks: chunks, memories: memories, toolNames: toolNames, history: history,
                historyBudget: historyBudget, style: style, ambient: ambient, todos: todos
            )
            grounding = contextPreamble + "\n\n" + native.text
            standing = nil
            stableContextChars = native.stableChars > 0 ? contextPreamble.count + 2 + native.stableChars : nil
        }
        Self.logTurnStart(chunks: chunks, tools: tools, grounding: grounding)
        // Fresh agent per turn — its reasoning trace must not bleed across
        // turns, and the tool list reflects current settings. The iteration cap is
        // read fresh too: `nil` keeps the configured base, else the live thermal
        // budget (never snapshotted at build time — the responder is long-lived).
        let iterations = maxIterationsProvider?() ?? maxIterations
        let agent = LocalAgent(
            inferenceProvider: provider,
            tools: tools,
            maxIterations: iterations,
            concludesOnUnstructuredThought: true,
            observationCharLimit: style == .react ? Self.reactObservationCharLimit : nil
        )
        // Per-turn reasoning budget (`thinkingEnabled`): decided ONCE for the turn
        // in `answerStreaming` (#555) — casual asks skip the think phase, grounded/
        // analytic asks keep it — and the same value is the turn's
        // `InferenceIntent.thinking`, so the tool session and every plain/synthesis
        // generation agree even if the voice toggle flips mid-turn.
        // A direct answer streams live only until the FIRST tool runs. After that
        // the model's free-form in-loop conclusion is unreliable — gemma emits a
        // content-free "let me look" preamble and ignores what the tools actually
        // returned (seen live). So once a tool dispatches we suppress the loose
        // conclusion and, when the loop ends, synthesise explicitly over the
        // gathered observations (gemma's competent grounded path) via `fallBack`.
        let emittedLive = Mutex(false)
        let toolUsed = Mutex(false)
        // The `use` arm: the first post-tool token follows whatever streamed before the tool (a
        // "Searching the web…" preface) — a paragraph break keeps the two from gluing (review fold).
        let postToolBreakPending = Mutex(true)
        do {
            let result = try await agent.run(
                goal: question,
                images: images,
                context: grounding,
                standing: standing,
                thinkingEnabled: thinkingEnabled,
                stableContextChars: stableContextChars,
                onEvent: { event in
                    if case .actionStarted = event { toolUsed.withLock { $0 = true } }
                    Self.forward(event, to: onActivity)
                },
                onConclusionToken: { token in
                    // Native small models free-form a content-free "let me look"
                    // preamble AFTER a tool and ignore what it returned, so once a
                    // tool runs we suppress the loose conclusion and synthesise
                    // explicitly below. The ReAct floor's CONCLUSION: contract is
                    // reliable — never suppress it (it carries the real answer).
                    // The `use` arm (PostToolAnswer) streams it and judges it after.
                    if style == .native, toolUsed.withLock({ $0 }) {
                        if postToolAnswerPolicy == .synthesise { return }
                        let first = postToolBreakPending.withLock { pending in
                            defer { pending = false }
                            return pending
                        }
                        if first, emittedLive.withLock({ $0 }) { continuation.yield("\n\n") }
                    }
                    emittedLive.withLock { $0 = true }
                    continuation.yield(token)
                },
                // Chain-of-thought streams into the same chat stream — the
                // chat-side splitter routes it to the reasoning disclosure.
                // Deliberately does NOT set emittedLive: reasoning alone is
                // not an answer, so the synthesis/fallback still fires.
                onReasoningToken: { token in
                    continuation.yield(token)
                }
            )

            let conclusion = result.conclusion
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let streamed = emittedLive.withLock { $0 }
            // Native tool turns synthesise via fallBack by default: gemma's loose
            // in-loop conclusion is unreliable filler, so even an error-only or
            // empty gather must route through fallBack (which filters errors and
            // degrades to plain RAG) rather than surface that conclusion. The
            // ReAct path keeps its reliable CONCLUSION:. Both still use the
            // empty-conclusion fallback for the no-tool case. Under the `use` arm
            // an answer-shaped conclusion stands (PostToolAnswer.verdict) and the
            // second generation is skipped — a preamble still synthesises, after it.
            let postTool: PostToolAnswer.Verdict? = style == .native && !result.toolsUsed.isEmpty
                ? PostToolAnswer.verdict(
                    policy: postToolAnswerPolicy, conclusion: conclusion, streamed: streamed,
                    evidence: !Self.informativeObservations(result.reasoningTrace).isEmpty
                )
                : nil
            let synthesiseOverEvidence: Bool
            let synthesisAfterPreamble: Bool
            switch postTool {
            case let .synthesise(afterPreamble):
                synthesiseOverEvidence = true
                synthesisAfterPreamble = afterPreamble
            case .keepConclusion:
                synthesiseOverEvidence = false
                synthesisAfterPreamble = false
                Self.log.notice("post-tool answer kept: \(conclusion.count) chars from the loop, no synthesis")
            case nil:
                synthesiseOverEvidence = false
                synthesisAfterPreamble = false
            }
            // A ReAct turn can stream a preamble ("Let me check.") before the tool
            // call it ends with, then conclude empty: something streamed, but not
            // the answer. It falls back like a silent turn, after the preamble.
            let danglingPreamble = style == .react && streamed && conclusion.isEmpty
            if synthesiseOverEvidence || (!streamed && conclusion.isEmpty) || danglingPreamble {
                await fallBack(
                    question: question, chunks: chunks, contextLine: contextLine,
                    result: result, synthesising: synthesiseOverEvidence,
                    afterPreamble: danglingPreamble || synthesisAfterPreamble, into: continuation
                )
            } else {
                var tail = streamed ? "" : conclusion
                tail += Self.webSourcesBlock(for: result)
                tail += Self.factSourcesBlock(for: result)
                if !tail.isEmpty {
                    continuation.yield(tail)
                }
                Self.logTurnDone(
                    streamed: streamed, tailCount: tail.count, result: result
                )
            }
            continuation.finish()
        } catch is CancellationError {
            Self.log.notice("turn cancelled mid-loop")
            continuation.finish()
        } catch {
            Self.log.error("agent threw — falling back to plain RAG: \(error, privacy: .public)")
            await streamFallback(
                question: question, chunks: chunks, contextLine: contextLine,
                afterPreamble: style == .react && emittedLive.withLock { $0 }, into: continuation
            )
            continuation.finish()
        }
    }

    /// Sources the model gathered itself via search_knowledge this turn —
    /// merged into the message's sources (and the citation allow-list) by
    /// ChatSession once the stream completes.
    public func collectedSources() -> [ChunkHit] {
        // The citation gate re-applies the withhold: a tool that slipped an
        // excluded kind into the collector never becomes a source.
        (sourceCollector?.drain() ?? []).filter { !excludedKinds.contains($0.kind) }
    }

    /// One line per retrieved hit with both relevance signals, so the gate
    /// thresholds can be tuned on real queries from the unified log.
    private static func logGateDecision(retrieved: [ChunkHit], kept: [ChunkHit]) {
        let keptIDs = Set(kept.map(\.chunkID))
        for hit in retrieved {
            let similarity = hit.similarity.map { String(format: "%.3f", $0) } ?? "–"
            let fused = hit.rrfScore.map { String(format: "%.4f", $0) } ?? "–"
            let verdict = keptIDs.contains(hit.chunkID) ? "kept" : "gated"
            let chunk = hit.chunkID.uuidString
            // .notice, like the summary line below and for the same reason: this
            // is the ONLY instrument that can say what a wrong hit actually
            // scored, and .debug does not persist in OSLogStore — so every
            // question about the floors was being answered from inference. Asked
            // for by name on 2026-08-12 after a screenplay was retrieved for a
            // question about dinner: measure before moving a threshold.
            //
            // ★ ID, never the TITLE. The title was here while this was `.debug`,
            // which the logging daemon does not persist; promoting the line to
            // `.notice` would have carried document titles into `OSLogStore` and
            // from there into the issue report — the one deliberate exception to
            // "nothing leaves this device" — where the scrub knows about paths,
            // emails and the user's name, but has no notion of corpus content. A
            // title can BE the sensitive part ("MRI results.pdf", someone's name).
            // The sibling quarantine sweeps in this same change log ids only for
            // exactly this reason. Map an id back with `get_document` or a store
            // query when a hit needs identifying; the score is what the
            // instrument exists to report.
            log.notice(
                "gate \(verdict, privacy: .public): sim=\(similarity, privacy: .public) rrf=\(fused, privacy: .public) chunk=\(chunk, privacy: .public)"
            )
        }
        let retrievedCount = retrieved.count
        let keptCount = kept.count
        // .notice (not .info): the gate decision is load-bearing for diagnosing a
        // bad retrieval from a captured issue report, where .info/.debug don't persist.
        log.notice("grounding gate: kept \(keptCount)/\(retrievedCount)")
    }

    /// Map agent-loop events to UI activity.
    private static func forward(
        _ event: AgentLoopEvent,
        to onActivity: @Sendable (ResponderActivity) -> Void
    ) {
        switch event {
        case let .thinking(iteration):
            onActivity(.thinking(iteration: iteration))
        case let .actionStarted(tool, argument):
            onActivity(.usingTool(name: tool, argument: argument))
        }
    }

    // MARK: - Diagnostics (unified logging)

    private static func logTurnStart(chunks: [ChunkHit], tools: [any AgentTool], grounding: String) {
        let toolNames = tools.map(\.name).sorted().joined(separator: ", ")
        // .notice: retrieval count + grounding size at turn start is a primary
        // breadcrumb — it must survive into a default-level issue-report capture.
        log.notice("""
        turn start: \(chunks.count) chunk(s) retrieved, tools=[\(toolNames, privacy: .public)], \
        grounding=\(grounding.count) chars
        """)
    }

    private static func logTurnDone(streamed: Bool, tailCount: Int, result: AgentResult) {
        let toolsUsed = result.toolsUsed.sorted().joined(separator: ", ")
        log.info("""
        turn done: streamedLive=\(streamed), tail=\(tailCount) chars, \
        toolsUsed=[\(toolsUsed, privacy: .public)]
        """)
    }

    /// The loop produced nothing usable as an answer — but its tools may have
    /// gathered real information. Synthesise from that (plain RAG only when
    /// there's truly nothing), keeping the deterministic web-sources block.
    private func fallBack(
        question: String,
        chunks: [ChunkHit],
        contextLine: String,
        result: AgentResult,
        synthesising: Bool = false,
        afterPreamble: Bool = false,
        into continuation: AsyncStream<String>.Continuation
    ) async {
        let steps = result.reasoningTrace.count
        // Two different roads end here — say which (the "returned empty" line
        // read as a failure on every native tool turn, live 2026-09-04).
        if synthesising {
            Self.log.notice("native tool turn: synthesising over \(steps) trace step(s)")
        } else {
            Self.log.notice("agent returned empty (nothing streamed) — falling back with \(steps) trace step(s)")
        }
        await streamFallback(
            question: question, chunks: chunks, contextLine: contextLine,
            gathered: result.reasoningTrace, afterPreamble: afterPreamble, into: continuation
        )
        let provenance = Self.webSourcesBlock(for: result) + Self.factSourcesBlock(for: result)
        if !provenance.isEmpty {
            continuation.yield(provenance)
        }
    }

    /// Grounded generation — the safety net when the agent loop fails. Uses
    /// the tool observations the loop already gathered when there are any
    /// (don't throw away a good web search because the model fumbled the
    /// CONCLUSION format), else the plain RAG prompt.
    ///
    /// With nothing yielded yet, the raw provider chunks (cumulative or delta)
    /// fold correctly downstream and pass through untouched. `afterPreamble`: a
    /// ReAct preamble already streamed, so the answer starts a paragraph on and
    /// every chunk goes out as a DELTA — the consumer's fold compares against
    /// text that now includes the preamble, and would read each cumulative
    /// snapshot (Apple Foundation Models streams those) as new text.
    /// Returns whether anything was yielded (the dispatched turn must not end blank).
    @discardableResult
    private func streamFallback(
        question: String,
        chunks: [ChunkHit],
        contextLine: String,
        gathered: [ReasoningStep] = [],
        afterPreamble: Bool = false,
        into continuation: AsyncStream<String>.Continuation
    ) async -> Bool {
        // The same provider may have gone away mid-turn (profile switch during a
        // multi-iteration ReAct loop). Yield the message instead of a hollow stream.
        if !provider.isAvailable {
            if afterPreamble { continuation.yield("\n\n") }
            continuation.yield(
                "Sorry — my brain went offline mid-answer. "
                    + "Try switching to another brain in Settings, or ask again in a moment."
            )
            return true
        }
        let body = Self.fallbackPrompt(question: question, chunks: chunks, gathered: gathered)
        // Carry the same per-turn context (precise date + active brain) the agent
        // path got, so a "what day is it?" that collapses to the fallback still answers.
        let prompt = contextLine.isEmpty ? body : contextLine + "\n\n" + body
        guard afterPreamble else {
            var yielded = false
            for await chunk in provider.generateStreaming(prompt: prompt) {
                if !chunk.isEmpty { yielded = true }
                continuation.yield(chunk)
            }
            return yielded
        }
        var sent = ""
        for await chunk in provider.generateStreaming(prompt: prompt) {
            let delta = StreamFold.delta(current: sent, chunk: chunk)
            guard !delta.isEmpty else { continue }
            if sent.isEmpty { continuation.yield("\n\n") }
            sent += delta
            continuation.yield(delta)
        }
        return !sent.isEmpty
    }

    /// The gathered steps that carry something a reader could use: a tool that ran and came back
    /// with neither an error nor a "you already ran" repeat. The fallback prompt is built over these,
    /// and a post-tool conclusion may stand (PostToolAnswer `.use`) only when there is at least one.
    static func informativeObservations(_ gathered: [ReasoningStep]) -> [(action: String, observation: String)] {
        gathered.compactMap { step -> (action: String, observation: String)? in
            guard let action = step.action,
                  let observation = step.observation,
                  !observation.hasPrefix("Error"),
                  !observation.hasPrefix("You already ran")
            else { return nil }
            return (action, observation)
        }
    }

    /// Pure fallback-prompt assembly: informative tool observations win;
    /// otherwise the standard grounded prompt.
    static func fallbackPrompt(
        question: String, chunks: [ChunkHit], gathered: [ReasoningStep]
    ) -> String {
        // ONE filter, so "what lands in the prompt" and "was a page read" can
        // never disagree (#209 review 2: two copies of this predicate) — and, since
        // 2026-10-25, whether the `use` arm may keep the loop's own answer.
        let survivors = informativeObservations(gathered)
        let observations = survivors.map { "\($0.action):\n\($0.observation)" }
        guard !observations.isEmpty else {
            return ChatPromptBuilder.build(chunks: chunks, userMessage: question)
        }
        // A page the user asked for and a tool READ is not a search hit to be
        // premise-checked — it is the thing itself. Without this the synthesis
        // over m1k3.app's own text came back "we don't go there — no fetch, no
        // pull" (live 2026-09-04): the persona answered instead of the page.
        // Only a read whose observation SURVIVED the filter above counts — a
        // fetch that errored beside a good search must not frame the prompt as
        // a page read (#209 review).
        let pageRead = survivors.contains {
            $0.action.hasPrefix("fetch_page") || $0.action.hasPrefix("open_link")
        }
        return """
        Answer the user's question using the INFORMATION GATHERED below. Be \
        direct and plain — do not mention tools or actions.

        First check the gathered information actually answers the question. If it \
        does NOT establish that the thing asked about exists — it only mentions the \
        words separately, or covers a related-but-different topic — say plainly you \
        couldn't confirm it, and don't present a guess as fact. Do NOT stitch \
        tangential mentions into an affirmative answer.

        \(pageRead ? Self.pageReadSynthesisLine + "\n" : "")INFORMATION GATHERED:
        \(observations.joined(separator: "\n\n"))

        USER: \(question)
        """
    }

    /// Appended to the synthesis prompt when a page was READ (fetch_page /
    /// open_link): the page's own words outrank what the model already believes
    /// about the site — including a site about itself.
    static let pageReadSynthesisLine =
        "A page that was read below IS the thing asked about: describe it from its own "
            + "words — its title, what it says, what it offers — not from what you already "
            + "believe about it."

    /// The most of one tool result a ReAct iteration carries forward. The ReAct
    /// floor is Mini: its ~3.2k-token fixed prompt (persona, tools, rules) left a
    /// 2,879-char web page no room — 4,209 of 4,096 tokens on the installed app,
    /// 2026-09-14. 1,200 chars (~300 tokens) keeps the iteration and its answer
    /// inside the window; the fallback still reads the whole observation.
    static let reactObservationCharLimit = 1200

    /// Which loop the prompt is feeding. The ReAct floor NEEDS its format
    /// scaffold (CONCLUSION:/call budget); the native loop speaks structured
    /// calls, and feeding it the ReAct scaffold makes reasoning models burn
    /// their think budget obeying a format they never emit (seen live on
    /// Qwen3.5-9B agonising over "CONCLUSION:" for a casual greeting).
    enum PromptStyle {
        case react
        case native
    }

    /// The grounding handed to the agent: the retrieved knowledge (with the
    /// same citation labels the validator expects) + tight behavioral rules
    /// tuned for small models. The tool-routing lines match what's actually
    /// callable — never advertise a disabled web_search (and never imply
    /// search_knowledge can reach the live world; the ⌘R weather bug).
    ///
    /// This is the native loop's layout verbatim. The ReAct floor gets the same
    /// words through `reactParts`, with the rules moved into its stable head.
    static func grounding(
        chunks: [ChunkHit], memories: [ChunkHit] = [], toolNames: Set<String>,
        history: [ChatTurn] = [], historyBudget: HistoryWindow.Budget = .default,
        style: PromptStyle = .react, now: Date = Date(), ambient: String? = nil,
        todos: String? = nil
    ) -> String {
        groundingWithStablePrefix(
            chunks: chunks, memories: memories, toolNames: toolNames, history: history,
            historyBudget: historyBudget, style: style, now: now, ambient: ambient, todos: todos
        ).text
    }

    /// `grounding` plus where its stable prefix ends (2026-10-26): the replay's character count — the
    /// part the next turn's render continues while the history window's start holds (HistoryWindow's
    /// block eviction). Zero without a replay. The agent maps it onto the tool session's `stablePrefix`.
    static func groundingWithStablePrefix(
        chunks: [ChunkHit], memories: [ChunkHit] = [], toolNames: Set<String>,
        history: [ChatTurn] = [], historyBudget: HistoryWindow.Budget = .default,
        style: PromptStyle = .react, now: Date = Date(), ambient: String? = nil,
        todos: String? = nil
    ) -> (text: String, stableChars: Int) {
        let body = groundingBody(
            chunks: chunks, memories: memories, toolNames: toolNames, style: style, now: now,
            ambient: ambient, todos: todos
        )
        guard let replay = HistoryWindow.render(history, budget: historyBudget) else { return (body, 0) }
        return ("\(replay)\n\(Self.replayFraming)\n\n\(body)", replay.count)
    }

    /// The ReAct turn's grounding, split: `context` is what this turn brings
    /// (history, knowledge, memories, todos, what's open beside the chat) and
    /// `standing` is the RULES, which depend only on the palette and ride the
    /// loop's stable head. `context + "\n\n" + standing` is `grounding(style:
    /// .react)` byte for byte — the same words, only placed differently.
    static func reactParts(
        chunks: [ChunkHit], memories: [ChunkHit] = [], toolNames: Set<String>,
        history: [ChatTurn] = [], historyBudget: HistoryWindow.Budget = .default,
        now: Date = Date(), ambient: String? = nil, todos: String? = nil
    ) -> (context: String, standing: String) {
        let sections = groundingSections(
            chunks: chunks, memories: memories, toolNames: toolNames, now: now, ambient: ambient, todos: todos
        ).joined(separator: "\n\n")
        let context = HistoryWindow.render(history, budget: historyBudget)
            .map { "\($0)\n\(Self.replayFraming)\n\n\(sections)" } ?? sections
        return (context, rules(toolNames: toolNames, style: .react))
    }

    /// How a ReAct turn over this palette begins — the stable head the Mini
    /// launch warm hands `prewarm(promptPrefix:)`. For a backend that carries
    /// the persona (AFM); built by the same function the loop uses, so a live
    /// turn over the same palette begins with exactly these bytes.
    public static func reactPromptPrefix(tools: [any AgentTool]) -> String {
        ReActPrompt.head(tools: tools, standing: rules(toolNames: Set(tools.map(\.name)), style: .react))
    }

    /// Sits between the replay block and the grounding body. With Mini's replay
    /// deepened 1.9× on Golden Gate (2026-09-12) the model began re-emitting its
    /// previous M1K3 line as the new answer — and its follow-up chips with it.
    /// The header names the block; this line says what to DO with it. Outside
    /// `HistoryWindow`'s byte accounting on purpose (a fixed ~30 tokens).
    static let replayFraming =
        "(Earlier turns above are context only. Answer the NEW question below in fresh words — never repeat an earlier M1K3 line.)"

    /// The uncited personal-facts block: memories aren't sources to cite,
    /// they're things M1K3 simply knows about the user. Sits between
    /// KNOWLEDGE and RULES; absent when no memory cleared the gate.
    ///
    /// Tier 1 (scratch/dream-cycle/SPEC.md): dated hits render newest-first
    /// with a "(learned …)" prefix so the model resolves contradictions with
    /// recency, at read time. Undated hits (pre-Tier-1 payloads, fixtures)
    /// keep the byte-pinned bare line and sort after dated ones. Token cost:
    /// ~6–8 tokens per dated fact, outside GroundingBudget.fit's accounting —
    /// covered by the ~95-token slack between the 1100 cap and the ~1195
    /// measured reserve (07-20 instrument run), so not re-plumbed.
    private static func memoryBlock(_ memories: [ChunkHit], now: Date) -> String? {
        // #286: a visitor memory describing M1K3's OWN tooling ("M1K3's
        // interactive chat palette gained `recent_activity(...)`…") is
        // knowledge about the app, not a fact about the user — left in, it
        // trips the persona's own SELF/WIRING decline on innocent asks that
        // happen to echo a phrase from the memory's description of the
        // tool's output. Filtered at retrieval so legacy rows are covered
        // without a migration.
        let memories = usableMemories(memories)
        guard !memories.isEmpty else { return nil }
        let ordered = memories.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        // `-> String` is load-bearing: without it the two-return closure's
        // interpolations infer GRDB.SQL (also ExpressibleByStringInterpolation
        // in this module) and the block renders an SQL debug dump.
        let facts = ordered.map { hit -> String in
            guard let createdAt = hit.createdAt else { return "- \(hit.content)" }
            return "- (learned \(MemoryRecency.phrase(from: createdAt, to: now))) \(hit.content)"
        }.joined(separator: "\n")
        // The conflict clause is part of Tier 1: gemma-4-12B read the dated
        // pair and HEDGED ("either Ardmore or Dublin") until told how to break
        // ties; Qwen resolved on dates alone (memblock probe, 2026-07-30).
        // Header speaks TO the user (2026-09-11 byte-replay: facts written
        // "Kev is…" came back as "Kev's been digging into sci-fi" in a reply
        // addressed to Kev, and titles came back as "[Water with lemon]"
        // cites — 0/12 of either with this wording).
        // #447: "Weave facts in naturally" had Mini work an unrelated memory
        // (a race in Galway, a sourdough starter) into 7 of 10 plain answers;
        // a fact now rides along only when it helps. About +8 tokens, only on
        // a turn where a memory cleared the gate (MiniRetrievalNoiseEvalTests).
        return "WHAT I KNOW ABOUT YOU (remembered from past conversations. These lines are "
            + "ABOUT the person you are talking to — speak to them as \"you\", never about "
            + "them in the third person. Mention a fact only when it helps answer what they asked; "
            + "never cite, quote, or bracket a memory. Where facts conflict, trust the most "
            + "recently learned):"
            + "\n\(facts)"
    }

    /// The generative carve-out — the FIRST rule in BOTH prompt styles, shared
    /// verbatim so the wording can't drift between them (109 review nit; a
    /// pin test asserts both rendered prompts carry this exact text).
    static let generativeCarveOut =
        generativeCarveHead
            + "No tools, no grounding, no citations, no \"found nothing\"; those are for factual questions."

    /// The head both carve-outs share (2026-09-12): "build" and "make" named, a
    /// whole web page named, and the CAN-you question answered by doing it. Byte-
    /// replayed on Lil, n=4: "Pal, build me a website about this conversation"
    /// drew the wiring decline 4/4 on master and came back as the page 4/4 with
    /// this head plus the persona's making line.
    static let generativeCarveHead =
        "- A request to write, build, make, create, code, or compose something — a poem, "
            + "a script, a whole web page — is a task to DO, not a lookup: produce it, complete. "
            + "Asked whether you CAN make it, make it. "

    /// The carve-out when the "hands" (propose_script) are in the palette: still
    /// "just produce it", but a runnable SCRIPT routes to propose_script — a
    /// one-click review-and-install — instead of a code block the user has to
    /// save and chmod. Without this, the plain carve-out above ("just produce
    /// it. No tools") steers the model to PASTE the script and never call the
    /// tool (observed live 2026-08-23, the whole reason the hands looked inert
    /// even with the toggle on). Selected in `groundingBody`; a pin asserts
    /// both styles carry it verbatim when propose_script is offered.
    static let generativeCarveOutWithScripts =
        generativeCarveHead
            + "No grounding, no citations, no "
            + "\"found nothing\", and no tools — with ONE exception: when the user asks "
            + "you to write, create, or make a SCRIPT you could run on "
            + "\(HostPlatform.thisDevice), call propose_script with the full source "
            + "(a one-click review-and-install) instead of pasting it in a code block. "
            + "A web page or a document is not a script: write it as one complete "
            + "```html or ```markdown block. "
            + "Everything else generative — poems, stories, code snippets — is still "
            + "produced directly, no web_search, no lookup_fact."

    /// open_link SHOWS; fetch_page READS. Added 2026-09-04 after Lil, holding a
    /// bare "Opened host" observation, narrated a page it never read (Kev's
    /// dislike); the describe-only rule itself lives in `describeOnlyRouting`.
    /// Offered-only, like every routing line (a pin test asserts presence/absence).
    static let openLinkRouting =
        "- open_link shows a page beside the chat and returns a short brief of it; to "
            + "READ a page in full, use fetch_page."

    /// The same line when fetch_page isn't offered (web off) — a routing line
    /// never advertises a tool the model can't call.
    static let openLinkRoutingNoFetch =
        "- open_link shows a page beside the chat and returns a short brief of it."

    /// A user-given address is a READ, not a search. Live replay 2026-09-04:
    /// "fetch the web site m1k3.app" became web_search("m1k3.app website content
    /// and features") — the rules had only ever framed fetch_page as the way to
    /// read a DIFFERENT search result — and the loop's fallback then blended
    /// corpus chunks about the Android app into its read of the Mac site.
    static let fetchPageRouting =
        "- When the user gives an address — a URL or a domain like example.com — "
            + "read it directly with fetch_page; do not web_search for it."

    /// "What have we been up to this week?" is a READ of the stores (chats,
    /// memories, visitors, pulses, todos) through recent_activity — never a
    /// reconstruction from the history window, which holds one conversation's
    /// tail and nothing of the visitors or the heartbeat (2026-09-10).
    /// Offered-only, like every routing line (RecentActivityRoutingTests).
    ///
    /// 2026-10-09: "What were the busiest days this week?" drew a clarifying
    /// question from Lil (Qwen3.5) — "your calendar, a team, web traffic?" —
    /// in ~6/16 trials instead of the call (`tool-recent-busiest`). The second
    /// sentence settles the ambiguity in the rule itself: busy here means
    /// activity on this device, and the tool is the answer, not a question.
    static let recentActivityRouting =
        "- For what happened lately on \(HostPlatform.thisDevice) — recent chats, new memories, "
            + "visiting agents, heartbeat pulses, todos, how busy it's been — call recent_activity (window: today, "
            + "yesterday, or N days); do not reconstruct it from this conversation. "
            + "\"Busy\", \"busiest\" or \"most active\" days means activity on \(HostPlatform.thisDevice): "
            + "call recent_activity straight away; do not ask which kind of busy they mean."

    /// The web route (2026-09-12). Byte-replayed on Lil, n=4 per probe, master →
    /// this line plus the persona's matching bullet: "What's the newest Claude
    /// model?" 0/4 → 4/4 web_search; "Who won the All-Ireland hurling final this
    /// year?" 0/4 → 4/4 (it answered from memory that the final "hasn't occurred
    /// yet"). Injected notes had been suppressing the search, hence "even when
    /// notes were injected above". Residual: "How about OpenAI's Astra model?"
    /// stays 0/4 — Lil is sure it knows, and no wording moved it.
    static let currentWorldRouting = currentWorldRouting(notes: .above)

    /// Where the turn's notes sit relative to the rules: after them in the
    /// native layout, before them in the ReAct floor's stable-first one.
    enum NotesPlacement {
        case above
        case below
    }

    /// The web route, worded for where the notes are (the native wording is the
    /// byte-replayed one; the ReAct floor's only swaps "were injected above" for
    /// "appear below", because there the rules come first).
    static func currentWorldRouting(notes: NotesPlacement) -> String {
        let notesClause = switch notes {
        case .above: "even when notes were injected above"
        case .below: "even when notes appear below"
        }
        return "- For current or external information — weather, news, prices, results, anything "
            + "happening now or this year, the newest or latest of anything, or a name you don't "
            + "recognise — use web_search, \(notesClause): your notes hold the "
            + "past, not what's on now. Before saying something doesn't exist or hasn't happened, search."
    }

    /// Attached ONCE whenever a page tool is offered (a duplication pin asserts
    /// on the assembled prompt): describe only what actually came back.
    static let describeOnlyRouting =
        "- Describe a page only from what a tool returned — if it could not be read, "
            + "say so instead of describing it."

    /// The page-tool rules — search-deepen, direct address, open_link, and the
    /// shared describe-only line — each offered-only; empty when no page tool is offered.
    static func pageToolRouting(toolNames: Set<String>, hasWebSearch: Bool) -> String {
        let hasFetchPage = toolNames.contains("fetch_page")
        let hasOpenLink = toolNames.contains("open_link")
        var lines: [String] = []
        if hasWebSearch, hasFetchPage {
            lines.append(
                "- web_search returns snippets AND automatically reads the "
                    + "top result's page for you; after a search, use fetch_page only to read a "
                    + "DIFFERENT result in full, then conclude from the page text."
            )
        }
        if hasFetchPage {
            lines.append(Self.fetchPageRouting)
        }
        if hasOpenLink {
            lines.append(hasFetchPage ? Self.openLinkRouting : Self.openLinkRoutingNoFetch)
        }
        if hasFetchPage || hasOpenLink {
            lines.append(Self.describeOnlyRouting)
        }
        return lines.map { "\n" + $0 }.joined()
    }

    /// `ambient`: what's open beside the chat (BrowserContext.render), placed
    /// between the remembered facts and the rules — present only while the
    /// review panel shows a page, so every pinned prompt is unchanged when nil.
    /// `todos`: the rendered OPEN TODOS block, after the remembered facts and
    /// before what's open beside the chat — the same nil-is-byte-identical rule.
    private static func groundingBody(
        chunks: [ChunkHit], memories: [ChunkHit], toolNames: Set<String>, style: PromptStyle,
        now: Date, ambient: String? = nil, todos: String? = nil
    ) -> String {
        let sections = groundingSections(
            chunks: chunks, memories: memories, toolNames: toolNames, now: now, ambient: ambient, todos: todos
        )
        return (sections + [rules(toolNames: toolNames, style: style)]).joined(separator: "\n\n")
    }

    /// The RULES block for a palette — offered-only routing lines, the carve,
    /// the loop-specific format lines. Depends on nothing but the palette and
    /// the style, which is what lets the ReAct floor prewarm it.
    static func rules(toolNames: Set<String>, style: PromptStyle) -> String {
        let hasWebSearch = toolNames.contains("web_search")
        // Every routing line names only tools actually offered THIS turn —
        // the self-query gate withholds search_knowledge, and a rule that
        // advertises an uncallable tool invites a doomed dispatch attempt.
        let hasSearchKnowledge = toolNames.contains("search_knowledge")
        let webRoute = Self.currentWorldRouting(notes: style == .react ? .below : .above)
        var routing = switch (hasWebSearch, hasSearchKnowledge) {
        case (true, true):
            webRoute + " search_knowledge only "
                + "finds documents already stored on \(HostPlatform.thisDevice)."
        case (true, false):
            webRoute
        case (false, true):
            "- search_knowledge only finds documents already stored on "
                + "\(HostPlatform.thisDevice). You have no web access — if the stored knowledge can't "
                + "answer, say so plainly; do not guess."
        case (false, false):
            "- You have no web access — if you don't know, say so plainly; "
                + "do not guess."
        }
        routing += Self.pageToolRouting(toolNames: toolNames, hasWebSearch: hasWebSearch)
        if toolNames.contains("recent_activity") {
            routing += "\n" + Self.recentActivityRouting
        }
        if toolNames.contains("lookup_fact") {
            routing += "\n- Stable, well-known facts (who wrote a famous book, a "
                + "capital city, basic science — never the newest of anything) you can just "
                + "answer from what you know "
                + "— you're reliable there. Use lookup_fact only when you're genuinely "
                + "unsure, the detail is obscure or easy to mix up, or it could have "
                + "changed over time; then cite its Source."
        }
        // The hands reshape the generative carve-out: a runnable script routes
        // to propose_script, not a pasted code block (2026-08-23 live fix).
        let carveOut = toolNames.contains("propose_script")
            ? Self.generativeCarveOutWithScripts
            : Self.generativeCarveOut
        // Both styles' small-talk line still says "pick up one real thread (… a memory of
        // them, the hour)". Lil and Big read it against a real history; Mini, handed small
        // talk here instead of the plain route, would invent a past again (#428). If the
        // router's chat verdict ever loosens, take the clause out for Mini here too.
        return switch style {
        case .react:
            """
            RULES:
            \(carveOut)
            - Use tools proactively. When a question could benefit from a lookup, \
            search, or check — call the tool rather than guessing. Combine multiple \
            tool calls across iterations when the question has several parts.
            - Pure small talk — greetings, banter — needs no tools or knowledge: \
            reply starting with "CONCLUSION:", in your own voice, picking up one \
            real thread (what they said, a memory of them, the hour). A question about the \
            current world is NOT small talk, even phrased casually.
            - If the KNOWLEDGE already fully answers the question, reply \
            starting with "CONCLUSION:" — citing it directly.
            - Cite knowledge sources inline with citation tokens like \
            [Title §heading]; never invent citations.
            - Never present a fact, figure, or date you can't ground or verify \
            as certain; if you're unsure, say so plainly. Honesty beats a confident guess.
            - If a search or lookup comes back empty or fails, answer with explicit \
            uncertainty — name what you couldn't confirm — rather than presenting a guess as fact.
            - Never repeat a tool call with the same argument.
            - Questions about yourself — your configuration, design, or abilities — \
            are answered from your persona; never search stored documents for them.
            \(routing)
            """
        case .native:
            """
            RULES:
            \(carveOut)
            - Use tools proactively. When a question could benefit from a lookup, \
            search, or check — call the tool rather than guessing. Call multiple \
            tools in a single turn when the question has several parts.
            - Pure small talk — greetings, banter — needs no tools or knowledge — reply in \
            your own voice and pick up one real thread (what they said, a memory of them, the \
            hour). A question about the current world is NOT small talk, even phrased casually.
            - If the KNOWLEDGE above fully answers the question, answer from it directly.
            - Cite knowledge sources inline with citation tokens like \
            [Title §heading]; never invent citations.
            - Never present a fact, figure, or date you can't ground or verify \
            as certain; if you're unsure, say so plainly. Honesty beats a confident guess.
            - If a search or lookup comes back empty or fails, answer with explicit \
            uncertainty — name what you couldn't confirm — rather than presenting a guess as fact.
            - Never repeat a tool call with the same argument.
            - Questions about yourself — your configuration, design, or abilities — \
            are answered from your persona; never search stored documents for them.
            \(routing)
            """
        }
    }

    /// The turn's own sections, in order: the knowledge head, what M1K3 knows
    /// about the user, open todos, what's open beside the chat. nil sections
    /// are dropped, so an absent block is byte-identical to no block.
    private static func groundingSections(
        chunks: [ChunkHit], memories: [ChunkHit], toolNames: Set<String>,
        now: Date, ambient: String?, todos: String?
    ) -> [String] {
        let head: String
        if chunks.isEmpty {
            head = toolNames.contains("search_knowledge")
                ? "No stored knowledge was injected — the user's documents are "
                + "NOT in this context. If the question could concern their "
                + "stored documents, calls, or notes, call search_knowledge; "
                + "otherwise answer from what you genuinely know — and if you "
                + "don't, say so plainly rather than guessing."
                : "No stored knowledge matched this question."
        } else {
            let knowledge = chunks.enumerated().map { index, hit in
                "\(index + 1). \(ChatPromptBuilder.citationLabel(for: hit))\n\(hit.content)"
            }.joined(separator: "\n\n")
            // The hedge is deliberate and it is the cheap half of the fix for a
            // real failure (2026-08-12): asked what he had for dinner on 3 March,
            // M1K3 retrieved a fragment of a SCREENPLAY the user had stored and
            // narrated it — "a pomegranate being worked on by the High Priestess"
            // — before correctly saying it didn't know. Retrieval returns the
            // least-bad match for any question, so the head must not present it as
            // material the question is about. The empty branch above already tells
            // the model to say so plainly; this tells it these excerpts may have
            // nothing to do with the question at all.
            head = "KNOWLEDGE (excerpts from the user's own documents, calls and "
                + "notes, retrieved by similarity — they may be irrelevant to this "
                + "question; use only what genuinely answers it, and ignore the "
                + "rest rather than working it into the answer):\n\(knowledge)"
        }
        return [head, memoryBlock(memories, now: now), todos, ambient].compactMap { $0 }
    }
}
