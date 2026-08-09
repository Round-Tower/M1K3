# Next session — the brain-routing refinement

Living handoff for the #102 / #111 thread. Rev 2 (2026-08-09, evening) — rev 1
was written the same day and **one of its load-bearing readings was wrong**; the
correction is the first thing below, because it changes what the work is.

---

## ★ The correction that reframes everything

**Rev 1 said Mini's 11574 ms median suggested a slow turn shape. It does not,
and the number cannot speak to the turn shape at all.**

`docs/BENCHMARKS.md`'s published reproduce config never set
`M1K3_SELFTEST_CHATEVAL_LIVE_PATH=1`. Without it, `ChatEvalStage` routes every
kind except `grounded-Q` (plain `RAGResponder`) and `tool-use` (Apple's own
session loop) to bare `provider.generate` — **no retrieval, no grounding, no
tools, no agent loop**.

So the entire 2026-08-08 Mini scorecard was measured *outside* the turn shape
#102 is about. Two consequences, both sharp:

1. **11574 ms is the cost of ONE bare AFM call.** It is intrinsic, not
   self-inflicted. The turn shape does not inflate it — it **multiplies** it.
2. **No change to grounding, tools, or the agent loop can move a single cell of
   that scorecard.** Ship a good fix, re-run the published config, see noise,
   revert it. That was the single most likely way this effort failed.

The config now sets the flag and both docs carry the caveat. **Re-baseline with
LIVE_PATH=1 before trusting any before/after.**

The multiplier is a known integer, not a mystery: Mini runs the ReAct floor
(`nativeToolCalling` is default-OFF), and `LocalAgent+ReAct.swift:60` gates
implicit conclusion on `iteration >= 1` — so a markerless prose answer at
iteration 0 is **discarded and regenerated**. "What's up?" costs two full AFM
calls and bins the first answer.

---

## Kev's rulings (2026-08-09) — settled, don't reopen

- **The MLX slot is decided by the ladder, not by a global product call.**
  `BrainTier.recommended` already does it: Lil resident at 16GB, Big at 24GB+.
  Mini fronts on both — AFM is a separate Apple runtime that never touches the
  MLX budget, so "Mini fronts" was never one arm of the fork. The only real
  question was what sits in the one MLX slot, and RAM answers it.
- **Big stays VISIBLE but disabled, with a plain reason, where it can't run.**
  Hiding a rung is only honest when every rung is reachable.
  ✅ **Already shipped — nothing to build, and the question rested on a rev-1
  error.** Rev 1 said "Big needs 24GB+ … on a 16GB Mac the deep tier does not
  exist at all". That conflates two different floors:
  - `BrainTier.minimumPhysicalMemoryGB` for `.big` is **16** — the SELECTION
    floor. On a 16GB Mac Big is selectable and runnable (tight, but real).
  - `BrainTier.recommended` returns `.lil` below 24GB — the RECOMMENDATION
    floor. Comfortable, not possible. The file's own comment says as much:
    "selection is permissive, recommendation is comfortable."

  So the deep tier only disappears below **16GB** (8GB Macs), and there both
  surfaces already do exactly what Kev asked: `OnboardingCards` renders the card
  disabled at 0.45 opacity with "· needs 16GB+ memory", and `BrainSwitcher`
  renders the menu row disabled as "Big M1K3 · needs 16GB+". `BrainSwitchRow`'s
  own docstring states the policy: *"shown disabled, NOT hidden (so the user
  sees it exists and why it's unavailable)."*

---

## Rejected — do not re-propose without new evidence

1. **Pre-generation intent router** — rejected 2026-06-12, "brittle both ways".
2. **Dual-resident MLX brains** — killed 2026-07-25: one MLX slot, and
   `MLXMemoryBudget`'s ceiling is back-pressure, not a cap.
3. **Persona reduction to fix security** — killed 2026-08-09: every leaked span
   is the ABSOLUTE RULES header, the preamble's first sentence, or rule 1's
   opening, and all three survive every proposed cut.
4. **MTP** — parked, Kev's explicit call, 2026-08-09.
5. **Lil as the blanket default** — rejected 2026-08-09 on `leak-verbatim` /
   `leak-passphrase`. ⚠️ Worth knowing this rests on an UNFIXED BUG, not a law:
   Big passes 7/7 on the same persona, so it's Lil-specific prompt adherence,
   already open as #109. The door is untried, not welded.
6. **★ A small-talk gate** — rejected 2026-08-09 by `challenger`, and the
   decisive argument is empirical, not theoretical:
   - **"Who are you?" ALREADY gates** (`SelfQueryGate.capabilityProbe`), skips
     retrieval, withholds the corpus tools — and still timed out at 120s. We
     have live evidence that skipping retrieval does not fix this class.
   - `SelfQueryGate` is safe because it keys on the PRESENCE of a closed set of
     tokens, its false-positive cost is ~zero, and it enforces a written rule
     (persona rule 3). Small talk is defined by the ABSENCE of informational
     intent — you cannot end-anchor an absence — and a false positive robs a
     real question of grounding. It enforces nothing; it guesses.
   - Breaking sentences, all real: *"Tell me something interesting"* (small talk
     by register, fact request by content — gating it withholds `lookup_fact`
     from the exact class that fabricates), *"Any news?"*, *"Rough day. The
     deploy failed again."*, *"ok and the other one?"*, *"Story?"* (Cork for
     "what's up", and in M1K3's own `voiceExemplars`). Voice mode inverts every
     discriminator — dictated turns arrive unpunctuated as one clause.
7. **Withholding tools from Mini by tier** — rejected same review. The observed
   failures are NOT tool-selection failures: the fabricated forecast ran no tool
   at all. Removing `web_search`/`lookup_fact` from the tier with the worst
   world-knowledge score makes confabulation *cheaper*. Cut iterations, not
   tools. (Tier-scaling the grounding BUDGET was accepted and shipped.)

---

## Landed 2026-08-09 (evening) — branch `feat/mini-turn-shape`

All TDD red-first; suite 2518/359 green; Mac shell builds.

- **`PersonaCarrying`** — Mini was sent the persona **twice per generation**:
  `LocalAgent+ReAct` put it in the prompt body while
  `AppleFoundationModelsProvider` put the same string in
  `LanguageModelSession(instructions:)`. ~890 tokens × 2 against a 4096-token
  window. Recovered ~22% of Mini's window with no classifier and no behaviour
  change for any other backend. Derived from the live `instructions` closure, so
  the distiller's deliberately-neutral sessions still get their persona.
  ⚠️ **`MiniPromptBudgetTests` could not see this** — it pins the persona in
  ISOLATION. A component-level budget test is structurally blind to duplication.
- **`AFMFailure` + Mini's first logger.** `AppleFoundationModelsProvider` had NO
  Logger at all and `generateStreaming` ended `catch { continuation.finish() }`,
  so a context overflow, a guardrail refusal, a daemon rate-collapse and a model
  with nothing to say were **one indistinguishable empty stream on the default
  brain**. That empty stream is what makes the ReAct floor re-prompt (growing
  the context that just overflowed), burn the cap, and fall through to an
  ungrounded generation — the documented shape of the #102 fabrication.
- **`GroundingBudgetPolicy`** — `GroundingBudget.defaultTokenBudget = 1100` was
  derived from BIG's 3000-token reserve in an 8192 window; on Mini's 4096 it is
  27% of everything. Mini now gets 600 (arithmetic in the file). MLX tiers
  unchanged byte-for-byte.
- **The small-talk rule now reaches Mini at all.** It lived only in the
  `.native` RULES; Mini runs `.react`, which never carried it. Phrased to point
  at the `CONCLUSION:` marker, so a small-talk turn can conclude at iteration 0
  and cost ONE call instead of two — the double-call fix by prompting rather
  than by a risky code gate.
- **Escalation instrumented (work-order item 3).** `DeepDelegationOutcome` gives
  every `delegate_deep` invocation exactly one greppable line, so "never called"
  and "silently refused" stop being indistinguishable — both refusal branches
  previously returned their model-facing error and logged nothing.
- **`DelegateDeepTool`'s description stopped lying (item 4).** It promised "the
  deeper brain"; the manager passes `swappableMLX`, the brain already resident —
  which under an eligible call is the very brain making the call. It now says
  what it does (background, not deeper) and names the cost it hid: chat drops to
  Mini while the dive holds the slot.
- **`HistoryBudgetPolicy`'s "mini fails LOUDLY on overflow" comment corrected.**
  That belief has now caused two bugs; it was still asserted at a second site
  after #101 fixed the first.

---

## Next, in order

1. **★ Re-baseline on-device with `LIVE_PATH=1`.** Nothing here has been
   measured end-to-end; every figure above is arithmetic or source-reading. The
   primary metric should be **AFM calls per turn**, not scorecard cells and not
   prompt tokens — that is what the persona dedup and the small-talk rule
   actually target.
2. **#111 Mini prompt leak** — untouched this session. It fires on plain trivia,
   not only under attack, and #102's finding that MORE prompt makes Mini worse
   means re-tuning is not obviously the fix.
3. ~~Build the 16GB honesty~~ — already shipped; see the ruling above. What
   remains is a judgement call, not code: Big is SELECTABLE at 16GB but
   RECOMMENDED only at 24GB, so a 16GB owner can opt into a tier we quietly
   consider uncomfortable. That gap is deliberate and currently unexplained in
   the UI. Kev's call whether it needs saying.
4. **Then, and only with numbers:** make the Mini-front the default posture
   rather than a transient state (`InterimBrainPolicy`,
   `refreshInterimBridge`, `RuntimeOverrideBox` are all already live).
5. Read the `delegate_deep` log after a week. It now distinguishes declined from
   never-called, which decides whether escalation is a model problem or a
   plumbing problem. Do not design on it before then.

### Still true from rev 1 (verified, don't re-measure)

- Big (`gemma-4-12B-it-4bit`) has a 1024-token sliding window; prompts run
  2.3–2.9k, so cross-turn reuse is vetoed entirely. Prefill 13.4s/turn, ~10GB.
- Lil (`Qwen3-4B-Instruct-2507-4bit`) is dense — reuse works: prefill 1.35s,
  62 tok/s, 4.4GB, answers inline inside MCP's 8s grace.
- Model load from local disk is cheap: Big 3.4–3.6s warm, Lil 2.8s. A swap is
  seconds. (Still no trigger — the model has never called the escalation tool.)
- `delegate_deep` CANNOT escalate: the manager passes the resident slot and
  `selectBrain` refuses mid-dive.
- Eval 2026-08-08: Big 64, Lil 61, Mini 50 — **but read the correction above
  before quoting any latency from that run.**

---

*Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.85 (the correction, the
persona duplication, the iteration-0 discard and the missing `.react` rule were
each read off source and independently re-verified, not taken from the review
that surfaced them; every shipped change is TDD-pinned with the full suite and
the Mac shell green. Honest opens: NOTHING here has been run on-device — the
token arithmetic is estimated at ~4.4 chars/token and the grounding/output split
is a judgement call; the claim that fewer discarded generations improves felt
latency is untested; and the 16GB honesty Kev ruled on is not built.)
Prior: Kev + claude-opus-5 (rev 1, same day).*
