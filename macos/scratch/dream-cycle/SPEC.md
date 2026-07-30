# Memory Consolidation — the dream cycle, reshaped (v2)

**Status:** v2 after challenger + security-auditor passes (2026-07-30). v1's nightly-batch
headline was RESHAPED by the challenger (verdict: RESHAPE, two blocking objections
verified against source by hand) and hardened by the security audit (2 BLOCKING,
3 HIGH folded). The dream survives — as the last tier, earned by data, not the first.

Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.8 (design; every load-bearing
current-state claim verified against source — incl. re-verifying the challenger's two
central objections by hand before folding. Nothing has run yet). Prior: v1 this file
(same day; superseded — fittingly).

---

## 0. What the reviews established (verified, do not re-litigate)

1. **The memory GRAPH is not in the chat answer path.** The "WHAT I KNOW ABOUT YOU"
   block renders CORPUS hits (`GroundingGate.partition` on `kind == .memory` →
   `AgentRAGResponder.memoryBlock`, AgentRAGResponder.swift:609). `MemoryStore.recall`'s
   only callers: MCP tools, the Memories UIs (Mac + iOS), the eval. A graph-only
   consolidator cannot change a word M1K3 says. (Challenger #1 — hand-verified.)
2. **Corrections are plausibly eaten at write time.** `hasSemanticDuplicate` (cosine
   ≥ 0.90) `continue`s BEFORE the corpus ingest AND the graph dual-write
   (MemoryDistillationCoordinator.swift:81). "Kev lives in Dublin" → "Kev lives in
   Ardmore" differ by one proper noun; if that pair embeds ≥ 0.90, the correction is
   silently dropped and no second node ever exists to supersede. Which regime Kev's
   embedder is in is UNMEASURED. (Challenger #2 — hand-verified.)
3. **Recency-wins arbitration is a poisoning primitive.** `remember` over MCP
   (loopback, no rate limit) + "newer supersedes older" lets any local process author
   a fact that legitimately judges as contradicting a true fact and auto-wins by
   being newer. Closed-enum parsing bounds format escapes, NOT content-level
   poisoning. (Security B1.)
4. **Fact text in `.notice` logs can leak off-device.** `IssueReporter.recentLogs`
   harvests all app.m1k3 `.notice+` lines from the last 10 min with no category
   exclusion; `DiagnosticRedactor` scrubs structural PII only, not semantic fact
   content; the repo is public and issue reports are the likely response to "the
   overnight reorg looks wrong". Also: the `memoryGraph` log category has ZERO call
   sites today — there is no "existing practice" to defer to. (Security B2.)
5. **The reversibility story has an asymmetry.** `forget`'s one-step undo is real at
   the store, but `forget_memory` (MCP) finds candidates via `recall`, which filters
   superseded rows — a fact buried ≥ 2 supersedes deep is MCP-unrecoverable; only the
   in-app Settings lineage surface can repair it. (Security H1.)
6. **Un-memoized nightly judging compounds risk.** Rows are immutable; a borderline
   pair re-rolls the judge every night; cumulative false-positive probability trends
   to 1 over enough nights even at low per-trial rates. Single-run eval precision
   cannot see this. (Security H2.)
7. **`related(to:)` does not filter superseded rows** (MemoryStore.swift:625) and
   `related_memory` renders neighbours with no supersede marker — any supersede
   write ships the graph into split visibility. (Challenger #6 / Security H3.)
8. **Supersede + hash dedupe = permanently unlearnable facts.** Re-asserting a
   superseded fact hits its `factSourceRef` twin → `wasDeduped` → no graph write →
   the natural user repair silently fails. Any supersede design owes an
   un-supersede-on-reassert rule. (Challenger #7.)

## 1. The keystone that survives (unchanged from v1)

**Consolidation never writes new fact text. Ever.** Writes are limited to supersede
pointers and (later, if earned) edges between existing nodes. Kills confabulation at
authorship. Both reviews endorsed this; the security audit's sharpening: authorship
safety ≠ arbitration safety — the rules below exist for the arbitration half.

**Arbitration rules (fold of B1/H2, apply to EVERY tier that supersedes):**
- **Source trust:** an `mcp:remember`-sourced fact may LOSE a supersede but never
  auto-WIN one in v1 (winning requires a non-MCP source or explicit user action).
- **Verdict memoization:** judge verdicts cached per unordered pair + content hash
  (rows are immutable, so the cache never staleys); a judged pair is never re-asked.
- **High-stakes transparency:** every `.profile`/`.preference` supersede is named in
  full in the in-app ledger — sampling only for `.note`/`.episode`.
- **Logs carry counts + memory IDs ONLY** — never fact text (the "LENGTH + brain,
  never the text" discipline). Text renders only in-app and in SelfTest reports.

## 2. The reshaped plan — four tiers, each earning the next

### Tier 0 — MEASURE (one session, decides everything)
A SelfTest arm (`M1K3_SELFTEST_MEMSTAT=1`) + report:
- live node count · per-kind counts · full pairwise cosine histogram of Kev's real
  graph (n² over thousands of vectors = seconds, no judge involved)
- measured cosine for ~10 hand-authored known-contradiction pairs (the
  Dublin/Ardmore shape) and ~10 compatible same-subject pairs
- count of live pairs ≥ 0.90 (Pass-C's supposed population) and in [0.75, 0.90)
- distillation-eaten-correction probe: feed the distiller a scripted correction
  conversation against a seeded prior fact; report whether the correction survived
**This settles:** which regime finding #2 is in · whether contradiction pairs even
land in a mineable band or at ≥ 0.90 (challenger #4: the v1 band was subtraction
from inherited constants, not measurement) · whether the nightly batch has a target.

### Tier 1 — READ-TIME HONESTY: date the memory block (one afternoon, corpus, chat-visible)
`ChunkHit` gains `createdAt`; `memoryBlock` renders recency and sorts newest-first:
`- (learned 3 days ago) Kev lives in Ardmore`. The model resolves contradictions at
read time with the signal a human would use. Zero destructive writes, no scheduler,
no judge, no consent surface; reversible by deleting a string. Acts on the store
that actually feeds chat (finding #1). Gemma prompt-fragility rule applies: A/B the
block wording via the live-path CHATEVAL arm before shipping (the #40 instrument).

### Tier 2 — WRITE-TIME REPAIR: fix ingestion where the user is present (a session)
The moment of maximal information is the write, not 3am (challenger's Tier-1
steelman, adopted):
- **Fix the eaten-correction bug** per Tier-0's evidence: the ≥ 0.90 dedupe must
  distinguish restatement from correction before discarding (exact mechanism —
  lexical delta check vs judge-on-one-pair — chosen from the measurement).
- **Supersede-on-write** in `DistilledFactGraphAdapter.writeDistilledFact`: nearest
  live same-kind neighbour above a MEASURED bar → `remember(supersedes:)` instead of
  plain insert. One candidate (not n²), conversational context still exists, user
  present, blast radius one pair per fact. Arbitration rules §1 apply (a distilled
  fact CAN supersede an mcp:remember fact; never vice versa automatically).
- **Prerequisites shipped in the SAME PR** (findings #7/#8, non-negotiable):
  `related(to:)` gains a superseded filter (+ `related_memory` marks any
  deliberately-included superseded neighbour) · un-supersede-on-reassert: an exact/
  semantic dedupe hit whose twin is superseded/stale REVIVES the old fact (or
  un-supersedes) instead of silently skipping · corpus-twin transition is audited
  like `forget_memory`'s twin line (Security M2) — typed outcome, security-log on
  divergence.
- **Corpus twin of a superseded fact** (was §8.1, now a prerequisite decision):
  re-kinded out of retrieval with a DISTINCT marker — NOT bare
  `KnowledgeKind.quarantined`, which is documented operator-QA territory (Security
  M1). Proposal: same exclusion semantics, separate sub-kind/title-prefix, restored
  by the un-supersede rule.

### Tier 3 — THE DREAM, earned (only if Tier-0/2 data says residue remains)
Nightly Pass A only (contradiction sweep over pairs write-time repair can't reach —
cross-conversation, pre-existing backlog). Everything from v1's design that
survives, plus the folds:
- AFM-only judge (never wakes MLX); guardrail refusals counted separately from
  `DIFFERENT` (challenger #12) — the ledger reports "N unjudgeable", never a false
  clean night.
- Caps by JUDGE CALLS not candidates; uncapped candidate count logged nightly so
  the cap's shadow is visible (challenger safeguard).
- **Judge-stability gate replaces naive idempotence:** same 50 pairs × 3 runs,
  disagreement rate reported; re-run after every macOS point release. Cap-driven
  "idempotence" proves nothing (challenger #8). Memoization (§1) then makes true
  idempotence structural rather than statistical.
- Scheduler reality: `NSBackgroundActivityScheduler`, app running, machine awake —
  "while you're away", not "while it sleeps" (challenger #10 killed the sleeping-Mac
  framing). Before building it: log the would-fire condition for two weeks; if the
  cadence is ~weekly, the batch can't converge and stays a debug-menu/SelfTest
  action instead.
- **Phase-1 dry run gates Phase-2 apply**: measured false-positive rate on Kev's
  real graph is the explicit precondition for default-ON (Security M3). First
  post-enable dream gets a deliberate (still non-modal) morning surfacing.
- **CUT from v1 of the dream:** Pass B (edge inference — persisting a token-overlap
  heuristic freezes its false positives into permanent traversal structure while the
  constellation already renders them disposably; challenger #11) and Pass C (twin
  merge — its ≥ 0.90 band is structurally unpopulated by an ingestion path that
  dedupes at 0.90; if Tier 0 finds residents, that's an ingestion bug to fix at
  Tier 2; challenger #3). Both may return with evidence.

### The journal (product moment, re-homed)
The "what changed" ledger is now fed by ALL tiers — write-time supersedes included —
so the romance doesn't wait for Tier 3: "While we talked, I updated what I know
about you" is real from Tier 2. Renders in-app (calm line, earned-moment pattern)
and in SelfTest reports; logs get counts + IDs only (§1). Never stored as a memory.

## 3. The double-bind, resolved explicitly

v1 claimed "safe because reversible" while designing for "invisible because gentle"
— the challenger named it: reversibility only mitigates if someone inspects.
Resolution: supersedes happen primarily AT WRITE TIME with the user present
(Tier 2); the unattended tier ships only after a dry-run shows a false-positive
rate low enough that nobody NEEDS to review it, with high-stakes kinds always named
in full. Quiet and safe stop being in tension because the risky arbitration moved
to where the user already is.

## 4. Phase-0 fixture list (merged: spec v1 §6 + challenger + security — pre-registered)

1. Contradiction resolved: seeded pair → supersede → recall returns newer, absent older.
2. False-supersede negatives: compatible same-subject + different-subject high-cosine
   pairs never supersede (target: zero across the set).
3. Source-trust asymmetry: mcp:remember fact never auto-wins over user/chat-sourced. (B1)
4. Adversarial well-formed content: crafted mcp fact that honestly judges as
   contradicting → deferred/flagged, not applied. (B1)
5. Verdict memoization: same immutable pair across two simulated nights → night 2 is
   a cache hit, zero judge calls. (H2)
6. Two-night chain: A←B←C → `forget_memory` lookup returns `.notConfident` for A/B
   AND the lineage query still yields the full chain (documents the H1 asymmetry).
7. `related(to:)` superseded filter + `related_memory` marker pinned. (H3/#7)
8. Un-supersede-on-reassert: re-asserted superseded fact revives through the dedupe
   path instead of vanishing. (#8)
9. Corpus-twin partial failure: corpus transition throws after graph commit → typed
   audit outcome + security-log line. (M2)
10. Ledger completeness: more profile/preference supersedes than the sample size →
    all named. (B1)
11. Interrupted night: wall-clock cap mid-pass → next night no double-apply/dupe edges.
12. Judge stability: 50 pairs × 3 runs disagreement rate (on-device arm); recorded
    per macOS build.
13. Mid-dream MCP write: fact written during a dream window isn't swept into that
    night's candidates without its own evaluation. (L1)
14. Dated-block rendering (Tier 1): recency phrasing + newest-first order pinned;
    live-path A/B before ship (gemma fragility rule).

## 5. Kev's calls (v2 — reordered by when they bite)

1. **Adopt the tier order?** Measure → date-the-block → write-time repair → dream.
   (The recommendation of both reviews and this spec.)
2. **Tier-1 block wording** — "(learned 3 days ago)" phrasing/shape: any taste call
   before the A/B?
3. **Corpus-twin marker** (Tier 2): separate sub-kind vs title-prefix under the
   existing exclusion semantics. Recommend: sub-kind (cleaner restore rule).
4. **Toggle** (Tier 3 only): own "Dream cycle" toggle default-ON-after-dry-run-gate
   vs default-OFF opt-in. Tier 2's write-time supersede rides `memoryAutoCapture`
   (it's part of capture); the unattended tier is the new consent boundary.
5. **Schedule framing** (Tier 3): any-idle-on-AC with 24h min ("while you're away")
   — accept the honest framing over the 3am romance?

## 6. Security posture (v2 — claims now matched to guarantees)

- On-device only; no MCP tool reads/writes dream state (verified: zero tools touch
  `memory_meta`). Judge sees stored fact text pairwise, never transcripts.
- Reversibility: real at the store; MCP-asymmetric (H1) — buried chains are app-only
  repairs, stated as policy; un-supersede-on-reassert restores the natural repair path.
- Poisoning: bounded by source-trust arbitration + memoization + full high-stakes
  ledger naming (B1/H2), not by parser format discipline alone.
- Leakage: fact text never enters unified logs (B2); in-app + SelfTest only.
- P3 taint: unchanged — consolidation recombines admitted facts only; the taint
  boundary stays single. (Narrow claim, per the audit: this defends authorship, not
  arbitration — arbitration is defended above.)
