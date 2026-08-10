//
//  DeepDiveTargetTests.swift
//  M1K3InferenceTests
//
//  Which brain a `delegate_deep` dive actually runs on.
//
//  Today: whichever is already resident. `AppEnvironment+DeepDelegation` passes
//  `provider: swappableMLX`, so a dive on a Lil machine runs on Lil — the same
//  brain that would have answered inline. The tool never escalated, which is
//  why its description had to stop promising "the deeper brain", and plausibly
//  why the model has never once called it: there was nothing there to want.
//
//  Kev's architecture (2026-08-10): "mini or lil — ideally always the fastest —
//  with a tool to delegate", and from the original goal, "push the 4B/3B tier,
//  and move to Big for deep reasoning — not always on". That only works if the
//  delegate tool can reach Big from a Lil front. This policy is that decision.
//
//  Measured context that makes it worth doing: Lil answers in 10.0s median
//  against Big's 30.5s and Mini's 37.3s (same build, live path, 2026-08-10). So
//  Lil is the right FRONT and Big is worth reaching only when depth is wanted —
//  exactly the split delegation is for.
//
//  Signed: Kev + claude-opus-5, 2026-08-11, Confidence 0.85 (pure and pinned;
//  the swap it authorises is app glue and remains verify-by-launch).
//  Prior: Unknown.
//

@testable import M1K3Inference
import Testing

struct DeepDiveTargetTests {
    @Test("a Lil front dives on Big — the escalation the tool has always promised")
    func lilFrontEscalatesToBig() {
        let plan = DeepDiveTarget.plan(
            resident: .lil, bigWeightsPresent: true, physicalMemoryGB: 64
        )
        #expect(plan.tier == .big)
        #expect(plan.requiresSwap)
    }

    @Test("a Big front dives on Big without touching the slot")
    func bigFrontNeedsNoSwap() {
        // Already resident: swapping would repay a multi-GB load and a cold
        // persona prefix for no gain (the same reason selectBrain no-ops a
        // re-selection of the loaded brain).
        let plan = DeepDiveTarget.plan(
            resident: .big, bigWeightsPresent: true, physicalMemoryGB: 64
        )
        #expect(plan.tier == .big)
        #expect(!plan.requiresSwap)
    }

    @Test("★ an absent Big NEVER triggers a download from a model-invoked tool")
    func absentBigDoesNotDownload() {
        // The house rule the brain switcher already follows — "don't start a
        // multi-GB pull from one toolbar tap" — applies far more strongly here,
        // because nobody tapped anything: the MODEL decided. A background tool
        // must not commit the user to gigabytes of traffic.
        let plan = DeepDiveTarget.plan(
            resident: .lil, bigWeightsPresent: false, physicalMemoryGB: 64
        )
        #expect(plan.tier == .lil)
        #expect(!plan.requiresSwap)
        #expect(!plan.isEscalation)
    }

    @Test("a Mac that cannot run Big dives on the resident brain instead")
    func belowBigsFloorStaysResident() {
        // Swapping Big onto an 8GB Mac would swap-thrash, and a background dive
        // is the worst possible place to discover that.
        let plan = DeepDiveTarget.plan(
            resident: .lil, bigWeightsPresent: true, physicalMemoryGB: 8
        )
        #expect(plan.tier == .lil)
        #expect(!plan.requiresSwap)
    }

    @Test("★ 16GB does NOT auto-escalate — this is the AUTOMATIC path, so it uses the comfortable floor")
    func sixteenGigDoesNotAutoEscalate() {
        // Big's SELECTION floor is 16GB (tight-but-runnable) but its
        // RECOMMENDATION floor is 24GB. `BrainTier.cappedForThisMac` already
        // states the house rule this follows: "ease the automatic pick down to
        // what THIS Mac can run comfortably... Manual selection stays sovereign
        // (capped only on the AUTOMATIC path)."
        //
        // A model-invoked background tool deciding to load a 12B model IS the
        // automatic path — nobody chose it. A user who wants Big on a 16GB Mac
        // can still pick it themselves; the model may not pick it for them.
        let plan = DeepDiveTarget.plan(
            resident: .lil, bigWeightsPresent: true, physicalMemoryGB: 16
        )
        #expect(plan.tier == .lil)
        #expect(!plan.requiresSwap)
        #expect(!plan.isEscalation)
    }

    @Test("24GB and up auto-escalates — the recommendation floor is the bar")
    func twentyFourGigEscalates() {
        #expect(DeepDiveTarget.plan(
            resident: .lil, bigWeightsPresent: true, physicalMemoryGB: 24
        ).requiresSwap)
    }

    @Test("a user who already chose Big at 16GB keeps it — sovereignty cuts both ways")
    func manualBigAtSixteenIsHonoured() {
        // The cap applies to the AUTOMATIC pick, never to a manual one. If Big
        // is already resident on a 16GB Mac the user put it there deliberately,
        // and a dive must not demote them to Lil on their behalf.
        let plan = DeepDiveTarget.plan(
            resident: .big, bigWeightsPresent: true, physicalMemoryGB: 16
        )
        #expect(plan.tier == .big)
        #expect(!plan.requiresSwap)
    }

    @Test("a non-escalating dive is still worth running — it's a BACKGROUND lane")
    func nonEscalatingDiveStillRuns() {
        // Degrading to "same brain, in the background, while Mini fronts" is the
        // honest v1 behaviour and still buys the user something: their long task
        // stops blocking the conversation. It just isn't depth, and `isEscalation`
        // says so, so the observation copy can be truthful about which it was.
        let plan = DeepDiveTarget.plan(
            resident: .lil, bigWeightsPresent: false, physicalMemoryGB: 64
        )
        #expect(plan.tier == .lil)
        #expect(!plan.isEscalation)
    }

    @Test("escalation is exactly 'the dive runs somewhere better than the front'")
    func escalationDefinition() {
        #expect(DeepDiveTarget.plan(resident: .lil, bigWeightsPresent: true, physicalMemoryGB: 64).isEscalation)
        #expect(!DeepDiveTarget.plan(resident: .big, bigWeightsPresent: true, physicalMemoryGB: 64).isEscalation)
    }

    @Test("a swap is only ever requested when the target differs from the resident")
    func swapImpliesDifferentTier() {
        for resident in [BrainTier.lil, .big] {
            for present in [true, false] {
                for ram in [8.0, 16.0, 64.0] {
                    let plan = DeepDiveTarget.plan(
                        resident: resident, bigWeightsPresent: present, physicalMemoryGB: ram
                    )
                    if plan.requiresSwap {
                        #expect(plan.tier != resident, "swap to the brain already loaded")
                    } else {
                        #expect(plan.tier == resident)
                    }
                }
            }
        }
    }
}
