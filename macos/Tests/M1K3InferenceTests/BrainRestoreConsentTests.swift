//
//  BrainRestoreConsentTests.swift
//  M1K3InferenceTests
//
//  #237: the launch restore may EASE a persisted Mini to pocket on a device where
//  Apple Intelligence is blocked — and the warm that followed pulled 630 MB with
//  nobody tapping anything. The tap IS the download consent everywhere else
//  (VoiceTierRestore, the brain cards), so the restore must obey the same rule:
//  warm what the user chose or what is already on disk; an eased pick that would
//  download waits for a tap.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-06, Confidence 0.9 (pure table; Kev's
//  ruling "prompt once"). Prior: none (new file).
//

@testable import M1K3Inference
import Testing

struct BrainRestoreConsentTests {
    @Test("eased Mini → pocket with no weights on disk asks first, and keeps Mini meanwhile")
    func easedOntoMissingPocketAsks() {
        let outcome = BrainRestoreConsent.resolve(persisted: .mini, eased: .pocket, staged: { _ in false })
        #expect(outcome == .askFirst(.pocket, keep: .mini))
    }

    @Test("eased Mini → pocket with the weights already staged warms — no download, no question")
    func easedOntoStagedPocketWarms() {
        let outcome = BrainRestoreConsent.resolve(persisted: .mini, eased: .pocket, staged: { $0 == .pocket })
        #expect(outcome == .warm(.pocket))
    }

    @Test("the user's own pick warms even when it must download — that tap was the consent")
    func ownPickWarms() {
        #expect(BrainRestoreConsent.resolve(persisted: .pocket, eased: .pocket, staged: { _ in false }) == .warm(.pocket))
        #expect(BrainRestoreConsent.resolve(persisted: .lil, eased: .lil, staged: { _ in false }) == .warm(.lil))
    }

    @Test("easing back to Mini (Apple Intelligence returned) never asks — Mini has nothing to download")
    func easedBackToMiniWarms() {
        #expect(BrainRestoreConsent.resolve(persisted: .pocket, eased: .mini, staged: { _ in false }) == .warm(.mini))
    }

    @Test("a fresh install (nothing persisted) eased onto pocket asks, keeping the Mini default")
    func freshInstallAsks() {
        #expect(BrainRestoreConsent.resolve(persisted: nil, eased: .pocket, staged: { _ in false }) == .askFirst(.pocket, keep: .mini))
    }

    @Test("a memory-floor ease onto Mini is a warm, whatever was persisted")
    func floorEaseWarms() {
        #expect(BrainRestoreConsent.resolve(persisted: .lil, eased: .mini, staged: { _ in false }) == .warm(.mini))
    }
}
