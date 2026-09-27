//
//  AFMPrewarmUtilityLiveTests.swift
//  M1K3InferenceTests
//
//  Live, opt-in (`M1K3_AFM_EVAL=1`, app quit): a utility call on foreign instructions
//  (the conversation titler) leaves chat's prewarmed session armed. PR #424 review: the
//  slot drops on a key mismatch, so the neutral titler evicted the next turn's prewarm.
//  `consultsSlot` is the pure half (AFMPrefixPrewarmTests); this is the SDK half.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.85. Prior: none (new file).
//

import Foundation
@testable import M1K3Inference
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_AFM_EVAL"] == "1"), .serialized)
struct AFMPrewarmUtilityLiveTests {
    @Test("a call on foreign instructions leaves the chat prewarm armed; a chat call takes it")
    func utilityCallKeepsPrewarm() async throws {
        let provider = AppleFoundationModelsProvider()
        try #require(provider.isAvailable, "Apple Intelligence is not available to this process")
        provider.prewarm()
        #expect(provider.prewarmArmed)
        _ = try await InferenceIntent.withInstructions("You write short titles for chat conversations.") {
            try await provider.generate(prompt: "Title this: USER: hi ASSISTANT: hello")
        }
        #expect(provider.prewarmArmed, "the titler evicted chat's prewarm")
        try await Task.sleep(for: .seconds(20)) // the daemon falls over under back-to-back turns
        _ = try await provider.generate(prompt: "Say hello in five words.")
        #expect(!provider.prewarmArmed, "a chat call should have taken the warm session")
    }
}
