//
//  DownloadUsePolicyTests.swift
//  M1K3InferenceTests
//
//  B2 (pre-push review): in-use covers more than the label and the slot. Each case below is a
//  way a Remove used to delete weights something was about to read.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85. Prior: none (new file).

@testable import M1K3Inference
import Testing

struct DownloadUsePolicyTests {
    private static let bigID = BrainTier.big.mlxModelID
    private static func snap(
        selected: BrainTier = .lil, serving: String? = nil, escalated: String? = nil,
        directed: BrainTier? = nil, staged: BrainTier? = nil, removing: Set<BrainTier> = []
    ) -> BrainUseSnapshot {
        .init(selectedBrain: selected, servingModelID: serving, escalatedModelID: escalated,
              directedTarget: directed, stagedSwapTarget: staged, removing: removing)
    }

    @Test("the selected brain and the serving slot are in use")
    func selectedAndServing() {
        #expect(DownloadUsePolicy.isBrainInUse(.lil, Self.snap(selected: .lil)))
        #expect(DownloadUsePolicy.isBrainInUse(.big, Self.snap(serving: Self.bigID)))
        #expect(!DownloadUsePolicy.isBrainInUse(.big, Self.snap()))
    }

    @Test("a deep-dive escalation puts Big in use while the label stays Lil")
    func deepDive() {
        #expect(DownloadUsePolicy.isBrainInUse(.big, Self.snap(selected: .lil, escalated: Self.bigID)))
    }

    @Test("a directed switch and a staged auto-swap protect their target")
    func directedAndStaged() {
        #expect(DownloadUsePolicy.isBrainInUse(.big, Self.snap(directed: .big)))
        #expect(DownloadUsePolicy.isBrainInUse(.big, Self.snap(staged: .big)))
        #expect(!DownloadUsePolicy.isBrainInUse(.big, Self.snap(directed: .lil, staged: .lil)))
    }

    @Test("a tier mid-Remove is busy, and selectBrain must refuse it")
    func removing() {
        #expect(DownloadUsePolicy.isBrainInUse(.big, Self.snap(removing: [.big])))
        #expect(!DownloadUsePolicy.mayLoad(.big, removing: [.big]))
        #expect(DownloadUsePolicy.mayLoad(.lil, removing: [.big]))
    }
}
