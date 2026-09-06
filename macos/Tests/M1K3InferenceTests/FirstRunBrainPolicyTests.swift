//
//  FirstRunBrainPolicyTests.swift
//  M1K3InferenceTests
//
//  The one decision HelloView makes when "Say hello" is tapped: which brain
//  serves the first session. Mini-first is the product call (instant, zero
//  download) — but Mini is Apple Foundation Models, and AFM can be unavailable
//  three different ways that deserve three different answers. The invariants
//  with teeth:
//    · a re-run NEVER silently switches a non-Mini brain (Kev on Big stays on Big)
//    · a transient AFM asset sync (.notReady) NEVER triggers a 2.3GB download
//    · only a genuinely blocked AFM falls back to the Lil download, and the
//      user-fixable flavour (Apple Intelligence off) also offers the OS fix.
//
//  Signed: Kev + claude-fable-5, 2026-07-03, Confidence 0.9. Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-09-06 — the blocked fallback is pocket, not Lil. Confidence 0.9.

@testable import M1K3Inference
import Testing

struct FirstRunBrainPolicyTests {
    // MARK: - Fresh install (current brain is the Mini default)

    @Test("AFM available → use Mini, done instantly")
    func availableUsesMini() {
        #expect(FirstRunBrainPolicy.resolve(afm: .available, currentBrain: .mini) == .useMini)
    }

    @Test("AFM model not ready → stay on Mini and wait, never punish a transient sync with a download")
    func notReadyWaits() {
        #expect(FirstRunBrainPolicy.resolve(afm: .notReady, currentBrain: .mini) == .waitForMini)
    }

    @Test("Apple Intelligence off (user-fixable) → pocket (the Mini for devices without Apple Intelligence) fallback, offering the OS fix too")
    func blockedUserFixableOffersBoth() {
        #expect(
            FirstRunBrainPolicy.resolve(afm: .blocked(userFixable: true), currentBrain: .mini)
                == .downloadFallback(.pocket, offerAppleIntelligenceFix: true)
        )
    }

    @Test("device not eligible (hard block) → pocket fallback, no pointless OS-settings offer")
    func blockedHardDownloadsOnly() {
        #expect(
            FirstRunBrainPolicy.resolve(afm: .blocked(userFixable: false), currentBrain: .mini)
                == .downloadFallback(.pocket, offerAppleIntelligenceFix: false)
        )
    }

    // MARK: - Re-run onboarding (Settings promises "your brain is kept")

    @Test("re-run with a non-Mini brain keeps it, whatever AFM says")
    func rerunKeepsNonMini() {
        for afm in [AFMAvailability.available, .notReady, .blocked(userFixable: true), .blocked(userFixable: false)] {
            #expect(FirstRunBrainPolicy.resolve(afm: afm, currentBrain: .big) == .keepCurrent(.big))
            #expect(FirstRunBrainPolicy.resolve(afm: afm, currentBrain: .lil) == .keepCurrent(.lil))
        }
    }

    @Test("re-run on Mini re-evaluates AFM (it may have broken since first run)")
    func rerunOnMiniReEvaluates() {
        #expect(
            FirstRunBrainPolicy.resolve(afm: .blocked(userFixable: true), currentBrain: .mini)
                == .downloadFallback(.pocket, offerAppleIntelligenceFix: true)
        )
    }
}
