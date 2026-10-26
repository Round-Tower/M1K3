//
//  HistoryBudgetPolicyTests.swift
//  M1K3ChatTests
//
//  Brain-aware conversation-replay sizing. The load-bearing guarantee: on a
//  rotating-KV tier (gemma-4 "big", maxKVSize=8192) the computed budget can NEVER
//  produce a prompt that crosses the window — else the persona/grounding head
//  silently rotates out. The wide dense-Qwen tiers get a genuinely larger window,
//  capped only by the latency ceiling (replay prefill doesn't amortize).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-06 — pocket's clamped window pinned (cap + margin + sum inside 8192).
//  Confidence 0.9.
//
//  Review: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.9 — the measured Mini replay is unchanged at 4,096 and
//  grows at 8,192 without double-spending grounding's gain.
//
//  Review: Kev + claude-opus-5-5, 2026-10-16, Confidence 0.8 — the spoken cap: Big's voice replay holds about four
//  exchanges, tightens only, leaves the other tiers alone, and has an argv kill switch.
//  Review: Kev + claude-opus-5-5, 2026-10-17 — the spoken budget carries the earlier-user trace (#626) and still fits
//  inside the typed window.

import Foundation
@testable import M1K3Chat
import M1K3Inference
import Testing

struct HistoryBudgetPolicyTests {
    /// Token-equivalent of a char budget at the policy's conservative ratio.
    private func historyTokens(_ budget: HistoryWindow.Budget) -> Int {
        Int(Double(budget.totalChars) / HistoryBudgetPolicy.charsPerToken)
    }

    @Test("rotating tier (big): the total prompt provably stays under the 8192 window")
    func rotatingTierNeverCrossesWindow() {
        let reserved = 1500
        let gen = 1024
        let budget = HistoryBudgetPolicy.budget(for: .big, reservedTokens: reserved, generationTokens: gen)
        // reserved + generation + history + the rotating safety margin ≤ the window.
        let total = reserved + gen + historyTokens(budget) + HistoryBudgetPolicy.rotatingSafetyMarginTokens
        #expect(total <= BrainTier.big.approximateContextTokens)
        // And the per-turn cap can't push the rendered block over total (clamp invariant).
        #expect(budget.perTurnChars <= budget.totalChars)
    }

    @Test("wide tier (lil) gets a strictly larger window than big for the same reserves")
    func wideTierIsWiderThanRotating() {
        let reserved = 1500
        let gen = 1024
        let big = HistoryBudgetPolicy.budget(for: .big, reservedTokens: reserved, generationTokens: gen)
        let lil = HistoryBudgetPolicy.budget(for: .lil, reservedTokens: reserved, generationTokens: gen)
        #expect(lil.totalChars > big.totalChars)
    }

    @Test("the latency ceiling caps even a wide-context tier (prefill cost stays bounded)")
    func latencyCeilingCapsWideTier() {
        let lil = HistoryBudgetPolicy.budget(
            for: .lil, reservedTokens: 1500, generationTokens: 1024,
            latencyCeilingTokens: 8000
        )
        // lil's context budget is ~30K, so the 8000-token ceiling binds, not the window.
        #expect(historyTokens(lil) == 8000)
        // A tighter ceiling shrinks it further — the knob actually bites.
        let tighter = HistoryBudgetPolicy.budget(
            for: .lil, reservedTokens: 1500, generationTokens: 1024,
            latencyCeilingTokens: 4000
        )
        #expect(tighter.totalChars < lil.totalChars)
    }

    @Test("a tier whose reserves swamp its window yields an empty (not negative) budget")
    func degenerateReservesClampToZero() {
        let budget = HistoryBudgetPolicy.budget(
            for: .mini, reservedTokens: 5000, generationTokens: 4096 // > mini's 4096 window
        )
        #expect(budget.totalChars == 0)
        #expect(budget.perTurnChars == 0)
    }

    @Test("mini's small window yields a small budget, well under the wide tiers")
    func miniIsSmallButPositive() {
        let mini = HistoryBudgetPolicy.budget(for: .mini, reservedTokens: 1000, generationTokens: 1024)
        let lil = HistoryBudgetPolicy.budget(for: .lil, reservedTokens: 1000, generationTokens: 1024)
        #expect(mini.totalChars > 0)
        #expect(mini.totalChars < lil.totalChars)
    }

    @Test("the conservative mini budget is non-zero, under the wide default, and fits AFM's window")
    func conservativeMiniBudgetIsSafe() {
        let mini = HistoryBudgetPolicy.conservativeMiniBudget
        // Non-zero (mini keeps multi-turn) but well under the wide MLX default
        // (which would overflow AFM's ~4K window — the CRITICAL the reviewer caught).
        #expect(mini.totalChars > 0)
        #expect(mini.totalChars < HistoryWindow.Budget.default.totalChars)
        // Token-fits AFM: history + a generous persona/grounding/answer reserve ≤ window.
        let historyTokens = Int(Double(mini.totalChars) / HistoryBudgetPolicy.charsPerToken)
        #expect(historyTokens + 3000 <= BrainTier.mini.approximateContextTokens)
        // Per-turn fidelity beats the legacy 6×400 mangle, still bounded by total.
        #expect(mini.perTurnChars > 400)
        #expect(mini.perTurnChars <= mini.totalChars)
    }

    @Test("rotating tier (big): live generation is capped so prefill + decode fit the window TOGETHER")
    func rotatingTierGenerationCapped() {
        #expect(HistoryBudgetPolicy.generationTokenCap(for: .big) == HistoryBudgetPolicy.rotatingGenerationTokenCap)
        // The window guarantee end-to-end, at the REAL live numbers: a budget
        // sized with the cap as its generation reserve + a decode that can never
        // exceed that same cap stays under 8192 — including the safety margin.
        // (The earlier test's gen=1024 modelled a value the live path never used.)
        let budget = HistoryBudgetPolicy.budget(
            for: .big, reservedTokens: 3000,
            generationTokens: HistoryBudgetPolicy.rotatingGenerationTokenCap
        )
        let total = 3000 + HistoryBudgetPolicy.rotatingGenerationTokenCap
            + historyTokens(budget) + HistoryBudgetPolicy.rotatingSafetyMarginTokens
        #expect(total <= BrainTier.big.approximateContextTokens)
    }

    @Test("linear-KV tiers keep the default generation budget — no cap needed")
    func linearTiersKeepDefaultGeneration() {
        for tier in [BrainTier.mini, .lil] {
            #expect(HistoryBudgetPolicy.generationTokenCap(for: tier) == 4096, "\(tier.rawValue)")
        }
    }

    @Test("pocket's 8k window is clamped like Big's: capped generation, margin, and the sum stays inside")
    func pocketWindowClamped() {
        #expect(HistoryBudgetPolicy.generationTokenCap(for: .pocket) == HistoryBudgetPolicy.rotatingGenerationTokenCap)
        let budget = HistoryBudgetPolicy.budget(
            for: .pocket, reservedTokens: 3000,
            generationTokens: HistoryBudgetPolicy.rotatingGenerationTokenCap
        )
        let total = 3000 + HistoryBudgetPolicy.rotatingGenerationTokenCap
            + historyTokens(budget) + HistoryBudgetPolicy.rotatingSafetyMarginTokens
        #expect(total <= BrainTier.pocket.approximateContextTokens)
    }

    @Test("per-turn cap and turn ceiling are HistoryWindow's own constants — one home, no drift")
    func perTurnConstantsShareOneHome() {
        let budget = HistoryBudgetPolicy.budget(for: .lil, reservedTokens: 1000, generationTokens: 1024)
        #expect(budget.perTurnChars == HistoryWindow.maxCharsPerTurn)
        #expect(budget.maxTurns == HistoryWindow.maxTurns)
    }

    @Test("the rotating margin actually costs big some headroom vs an equivalent non-rotating window")
    func rotatingMarginIsApplied() {
        // big and a hypothetical 8192 non-rotating tier would differ by exactly the
        // margin; we assert big's history is reduced by the margin vs the raw context.
        let reserved = 1000
        let gen = 1024
        let big = HistoryBudgetPolicy.budget(for: .big, reservedTokens: reserved, generationTokens: gen)
        let rawContext = BrainTier.big.approximateContextTokens - reserved - gen
        #expect(historyTokens(big) <= rawContext - HistoryBudgetPolicy.rotatingSafetyMarginTokens + 1)
    }

    @Test("optional-tier overload owns the mini/unknown guard (112 review nit)")
    func optionalTierOverloadGuardsMiniAndUnknown() {
        // nil (unknown persisted brain string) and .mini both get the fixed
        // conservative replay — never the MLX-sized computation.
        let unknown = HistoryBudgetPolicy.budget(
            for: BrainTier(persisted: "not-a-brain"), reservedTokens: 3000, generationTokens: 2048
        )
        #expect(unknown == HistoryBudgetPolicy.conservativeMiniBudget)
        let mini = HistoryBudgetPolicy.budget(
            for: BrainTier?.some(.mini), reservedTokens: 3000, generationTokens: 2048
        )
        #expect(mini == HistoryBudgetPolicy.conservativeMiniBudget)
        // A real MLX tier delegates to the non-optional computation unchanged.
        let big = HistoryBudgetPolicy.budget(
            for: BrainTier?.some(.big), reservedTokens: 3000, generationTokens: 2048
        )
        #expect(big == HistoryBudgetPolicy.budget(for: .big, reservedTokens: 3000, generationTokens: 2048))
    }

    @Test("an image turn shrinks the replay window — vision tokens aren't free on the rotating tier")
    func imageReserveShrinksBudget() {
        // ~265 measured prompt tokens/image on gemma-4-12B (GemmaVisionSpike,
        // 2026-07-14) → the 300-token reserve is conservative; chars ≈ 4×tokens.
        let base = HistoryWindow.Budget(totalChars: 10000, perTurnChars: 4000, maxTurns: 8)
        // No images: identity — the default path is byte-identical.
        #expect(base.reservingImages(0) == base)
        // One image: total shrinks by the per-image char reserve.
        let one = base.reservingImages(1)
        #expect(one.totalChars == 10000 - HistoryBudgetPolicy.imageReserveCharsPerImage)
        #expect(one.maxTurns == base.maxTurns)
        // The rotating-KV clamp invariant survives: perTurn never exceeds total.
        #expect(one.perTurnChars <= one.totalChars)
        // Many images floor at zero rather than going negative.
        let flooded = base.reservingImages(100)
        #expect(flooded.totalChars == 0)
        #expect(flooded.perTurnChars == 0)
    }

    @Test("the live reserves are the policy's own — one home for both shells")
    func liveReservesAreShared() {
        #expect(HistoryBudgetPolicy.liveReserveTokens == 3000)
        #expect(HistoryBudgetPolicy.liveGenerationReserveTokens == HistoryBudgetPolicy.rotatingGenerationTokenCap)
    }

    // MARK: - Measured Mini budget (the [SPIKE] resolved, Golden Gate)

    @Test("measured mini budget: real token count yields a wider window than the conservative fallback")
    func measuredMiniBudgetIsWiderThanConservative() {
        // 462 tokens is the measured fixed prompt on Golden Gate (persona 214 +
        // tools 117 + grounding 102 + goal 16 + overhead 13).
        let measured = HistoryBudgetPolicy.measuredMiniBudget(reservedTokens: 462)
        let conservative = HistoryBudgetPolicy.conservativeMiniBudget
        #expect(measured.totalChars > conservative.totalChars,
                "measured \(measured.totalChars) should beat conservative \(conservative.totalChars)")
    }

    @Test("measured mini budget: the total still fits inside AFM's 4096-token window")
    func measuredMiniBudgetFitsWindow() {
        let measured = HistoryBudgetPolicy.measuredMiniBudget(reservedTokens: 462)
        let historyTokens = Int(Double(measured.totalChars) / HistoryBudgetPolicy.charsPerToken)
        #expect(historyTokens + 462 + 1024 <= BrainTier.mini.approximateContextTokens)
    }

    @Test("measured mini budget: swamped reserves clamp to zero, not negative")
    func measuredMiniBudgetClampsToZero() {
        let budget = HistoryBudgetPolicy.measuredMiniBudget(reservedTokens: 5000)
        #expect(budget.totalChars == 0)
        #expect(budget.perTurnChars == 0)
    }

    @Test("optional-tier overload: measuredMiniReserveTokens routes to the measured path")
    func optionalTierOverloadUsesMeasuredWhenProvided() {
        let withMeasured = HistoryBudgetPolicy.budget(
            for: BrainTier?.some(.mini),
            reservedTokens: 3000,
            generationTokens: 2048,
            measuredMiniReserveTokens: 462
        )
        let withoutMeasured = HistoryBudgetPolicy.budget(
            for: BrainTier?.some(.mini),
            reservedTokens: 3000,
            generationTokens: 2048
        )
        #expect(withMeasured.totalChars > withoutMeasured.totalChars,
                "measured path should yield a wider budget than conservative")
        #expect(withoutMeasured == HistoryBudgetPolicy.conservativeMiniBudget)
    }

    @Test("optional-tier overload: measuredMiniReserveTokens is ignored for non-Mini tiers")
    func measuredMiniReserveIgnoredForOtherTiers() {
        let big = HistoryBudgetPolicy.budget(
            for: BrainTier?.some(.big),
            reservedTokens: 3000,
            generationTokens: 2048,
            measuredMiniReserveTokens: 462
        )
        let bigWithout = HistoryBudgetPolicy.budget(
            for: .big, reservedTokens: 3000, generationTokens: 2048
        )
        #expect(big == bigWithout)
    }

    // MARK: - The device's window, not the author's Mac's (2026-09-27)

    @Test("at the 4,096 floor the measured Mini replay is exactly today's")
    func measuredMiniAtFloorIsUnchanged() {
        let today = HistoryBudgetPolicy.measuredMiniBudget(reservedTokens: 1466)
        let floor = HistoryBudgetPolicy.measuredMiniBudget(reservedTokens: 1466, windowTokens: 4096)
        #expect(today.totalChars == floor.totalChars)
        #expect(today.perTurnChars == floor.perTurnChars)
    }

    @Test("an 8,192 window buys Mini more replay — without double-spending grounding's gain")
    func measuredMiniGrowsWithTheWindow() {
        let persona = 1466, generation = 1024, window = 8192
        let small = HistoryBudgetPolicy.measuredMiniBudget(reservedTokens: persona, windowTokens: 4096)
        let big = HistoryBudgetPolicy.measuredMiniBudget(reservedTokens: persona, windowTokens: window)
        #expect(big.totalChars > small.totalChars)
        // Whatever grounding gained above its 4,096 baseline comes out of replay,
        // so the bigger window adds no overcommit the floor didn't already have.
        let groundingGain = GroundingBudgetPolicy.tokens(for: .mini, miniWindowTokens: window)
            - GroundingBudgetPolicy.tokens(for: .mini, miniWindowTokens: 4096)
        let historyTokens = Int(Double(big.totalChars) / HistoryBudgetPolicy.charsPerToken)
        #expect(historyTokens + persona + generation + groundingGain <= window)
    }

    @Test("a sub-floor window shrinks the replay and still fits — never negative")
    func measuredMiniBelowTheFloor() {
        let persona = 1466, generation = 1024, window = 2048
        let tiny = HistoryBudgetPolicy.measuredMiniBudget(reservedTokens: persona, windowTokens: window)
        let floor = HistoryBudgetPolicy.measuredMiniBudget(reservedTokens: persona, windowTokens: 4096)
        #expect(tiny.totalChars < floor.totalChars)
        #expect(tiny.totalChars >= 0)
        let historyTokens = Int(Double(tiny.totalChars) / HistoryBudgetPolicy.charsPerToken)
        #expect(historyTokens + persona + generation <= max(window, persona + generation))
    }

    // MARK: - Spoken replay (Big, voice mode)

    private func live(_ tier: BrainTier?, spoken: Bool) -> HistoryWindow.Budget {
        HistoryBudgetPolicy.budget(
            for: tier,
            reservedTokens: HistoryBudgetPolicy.liveReserveTokens,
            generationTokens: HistoryBudgetPolicy.liveGenerationReserveTokens,
            spoken: spoken
        )
    }

    @Test("a spoken turn on Big replays about four exchanges, not the full window")
    func spokenBigReplaysFourExchanges() {
        let typed = live(.big, spoken: false)
        let spoken = live(.big, spoken: true)
        #expect(spoken.maxTurns == 8)
        #expect(spoken.totalChars < typed.totalChars)
        // The 2026-10-16 rig run: eight turns of Big's spoken answers measured 4,186 chars.
        #expect(spoken.totalChars >= 4186)
        #expect(spoken.perTurnChars <= spoken.totalChars)
    }

    @Test("a spoken turn on Big traces evicted user turns, and the trace fits inside the typed window")
    func spokenBigTracesEarlierTurns() {
        let typed = live(.big, spoken: false)
        let spoken = live(.big, spoken: true)
        #expect(spoken.earlierUserChars == HistoryBudgetPolicy.spokenBigBudget.earlierUserChars)
        #expect(spoken.earlierUserChars > 0)
        // The rotating-window clamp: the trace rides inside what the typed replay was allowed.
        #expect(spoken.totalChars + spoken.earlierUserChars <= typed.totalChars)
    }

    @Test("no trace on typed turns or other tiers")
    func traceIsSpokenBigOnly() {
        #expect(live(.big, spoken: false).earlierUserChars == 0)
        for tier: BrainTier? in [.lil, .mini, .pocket, nil] {
            #expect(live(tier, spoken: true).earlierUserChars == 0)
        }
    }

    @Test("an image on a spoken Big turn still keeps the per-turn cap inside the total")
    func spokenBigWithImagesKeepsTheClamp() {
        for images in 0 ... 12 {
            let budget = live(.big, spoken: true).reservingImages(images)
            #expect(budget.perTurnChars <= budget.totalChars)
        }
    }

    @Test("spoken only tightens: every field is at most the typed figure")
    func spokenOnlyTightens() {
        for tier: BrainTier? in [.big, .lil, .mini, .pocket, nil] {
            let typed = live(tier, spoken: false)
            let spoken = live(tier, spoken: true)
            #expect(spoken.totalChars <= typed.totalChars)
            #expect(spoken.perTurnChars <= typed.perTurnChars)
            #expect(spoken.maxTurns <= typed.maxTurns)
        }
    }

    @Test("the spoken cap is Big's alone until another tier is measured")
    func spokenLeavesOtherTiersAlone() {
        for tier: BrainTier? in [.lil, .mini, .pocket, nil] {
            #expect(live(tier, spoken: true) == live(tier, spoken: false))
        }
    }

    @Test("the argv kill switch: -spokenHistoryCap NO turns the cap off, anything else leaves it on")
    func spokenCapKillSwitch() {
        #expect(HistoryBudgetPolicy.spokenCapEnabled(arguments: [:]))
        #expect(HistoryBudgetPolicy.spokenCapEnabled(arguments: ["spokenHistoryCap": "YES"]))
        for off in ["NO", "no", "0", "false", "off"] {
            #expect(!HistoryBudgetPolicy.spokenCapEnabled(arguments: ["spokenHistoryCap": off]))
        }
    }

    // MARK: - Block eviction (2026-10-26, design doc §2a)

    @Test("the Mac's MLX tiers evict history in blocks; Mini's and pocket's windows do not")
    func mlxTiersCarryTheBlock() {
        #expect(HistoryBudgetPolicy.defaultEvictionBlockTurns == 6)
        for tier in [BrainTier.lil, .big] {
            #expect(live(tier, spoken: false).evictionBlockTurns == HistoryBudgetPolicy.defaultEvictionBlockTurns)
            #expect(live(tier, spoken: false).minimumKeptTurns == HistoryWindow.maxTurns - 6)
        }
        // Pocket is the phone's tier and the tail checkpoint is desktop-only: a block would cost context for nothing.
        #expect(live(.pocket, spoken: false).evictionBlockTurns == 1)
        #expect(HistoryBudgetPolicy.conservativeMiniBudget.evictionBlockTurns == 1)
        #expect(HistoryBudgetPolicy.measuredMiniBudget(reservedTokens: 1500).evictionBlockTurns == 1)
        #expect(live(.mini, spoken: false).evictionBlockTurns == 1)
    }

    @Test("the image reserve keeps the block; spoken Big takes the smaller block of four")
    func blockSurvivesTheMerges() {
        let block = HistoryBudgetPolicy.defaultEvictionBlockTurns
        #expect(live(.lil, spoken: false).reservingImages(2).evictionBlockTurns == block)
        // Eight turns kept on a spoken Big turn: a block of six would leave two exchanges one message
        // in three. Four keeps six to eight, and the argv override can only lower it.
        let spoken = live(.big, spoken: true)
        #expect(spoken.evictionBlockTurns == 4)
        #expect(spoken.minimumKeptTurns == 4)
        let off = HistoryBudgetPolicy.budget(
            for: .big, reservedTokens: HistoryBudgetPolicy.liveReserveTokens,
            generationTokens: HistoryBudgetPolicy.liveGenerationReserveTokens, spoken: true, evictionBlockTurns: 1
        )
        #expect(off.evictionBlockTurns == 1)
        // Rendered: six or eight turns kept, never fewer, and the block stays inside the typed bound.
        let turns = (1 ... 30).map { i in
            ChatTurn(role: i.isMultiple(of: 2) ? .assistant : .user, text: String(repeating: "s", count: 500) + " \(i)")
        }
        let typed = live(.big, spoken: false)
        // Whole exchanges, as a turn's history arrives (an unanswered turn flips the parity: the orphan guard's case).
        for n in stride(from: 20, through: 30, by: 2) {
            let text = HistoryWindow.render(Array(turns.prefix(n)), budget: spoken) ?? ""
            let kept = text.components(separatedBy: "\n")
                .filter { $0.hasPrefix("USER: ") || $0.hasPrefix("M1K3: ") }.count
            #expect(kept == 6 || kept == 8, "n=\(n) kept \(kept)")
            #expect(text.count <= typed.totalChars)
        }
    }

    @Test("the distillation trigger reads the fewest turns the window keeps")
    func distillationFollowsTheFloor() {
        let lil = live(.lil, spoken: false)
        #expect(lil.minimumKeptTurns == HistoryWindow.maxTurns - HistoryBudgetPolicy.defaultEvictionBlockTurns)
        let n = lil.minimumKeptTurns + ChatSession.rollingDistillBatch
        #expect(!ChatSession.shouldRollingDistill(messageCount: n - 1, watermark: 0, replayTurns: lil.minimumKeptTurns))
        #expect(ChatSession.shouldRollingDistill(messageCount: n, watermark: 0, replayTurns: lil.minimumKeptTurns))
    }

    @Test("the argv override: -historyEvictionBlock N sets the block, 0/1/NO turn it off, junk is the default")
    func evictionBlockArgv() {
        let block = HistoryBudgetPolicy.defaultEvictionBlockTurns
        #expect(HistoryBudgetPolicy.evictionBlockTurns(arguments: [:]) == block)
        #expect(HistoryBudgetPolicy.evictionBlockTurns(arguments: ["historyEvictionBlock": "8"]) == 8)
        #expect(HistoryBudgetPolicy.evictionBlockTurns(arguments: ["historyEvictionBlock": "1"]) == 1)
        #expect(HistoryBudgetPolicy.evictionBlockTurns(arguments: ["historyEvictionBlock": "0"]) == 1)
        #expect(HistoryBudgetPolicy.evictionBlockTurns(arguments: ["historyEvictionBlock": "NO"]) == 1)
        #expect(HistoryBudgetPolicy.evictionBlockTurns(arguments: ["historyEvictionBlock": "lots"]) == block)
        // The argument domain may hand a numeric value over as a number; a huge or negative one is clamped.
        #expect(HistoryBudgetPolicy.evictionBlockTurns(arguments: ["historyEvictionBlock": NSNumber(value: 8)]) == 8)
        #expect(HistoryBudgetPolicy.evictionBlockTurns(arguments: ["historyEvictionBlock": NSNumber(value: 0)]) == 1)
        let huge = ["historyEvictionBlock": "9223372036854775807"]
        #expect(HistoryBudgetPolicy.evictionBlockTurns(arguments: huge) == 64)
        #expect(HistoryBudgetPolicy.evictionBlockTurns(arguments: ["historyEvictionBlock": "-3"]) == 1)
        let off = HistoryBudgetPolicy.budget(
            for: .lil, reservedTokens: 1000, generationTokens: 1000, evictionBlockTurns: 1
        )
        #expect(off.evictionBlockTurns == 1)
    }
}
