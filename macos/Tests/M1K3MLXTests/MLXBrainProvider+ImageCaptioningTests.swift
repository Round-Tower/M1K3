//
//  MLXBrainProvider+ImageCaptioningTests.swift
//  M1K3MLXTests
//
//  Caption memory: the caption session never carries the persona and always
//  runs with thinking off. Pure pins -- the model-backed path (an image in, a
//  caption out) is verify-by-launch.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8, Prior: Unknown

import Foundation
import M1K3Inference
@testable import M1K3MLX
import Testing

struct MLXBrainProviderImageCaptioningTests {
    @Test("a caption session has no persona fallback: no instructions override is an error, not the persona")
    func captionInstructionsRefuseToFallBackToThePersona() throws {
        #expect(try MLXBrainProvider.captionInstructions(override: "Describe it.") == "Describe it.")
        #expect(throws: InferenceError.self) { try MLXBrainProvider.captionInstructions(override: nil) }
        #expect(throws: InferenceError.self) { try MLXBrainProvider.captionInstructions(override: "  \n") }
    }

    @Test("a caption turn forces thinking off wherever the template has the switch, whatever the provider's setting")
    func captionTurnForcesThinkingOff() {
        let off = MLXBrainProvider.captionAdditionalContext(supportsThinkingToggle: true)
        #expect(off?["enable_thinking"] as? Bool == false)
        #expect(MLXBrainProvider.captionAdditionalContext(supportsThinkingToggle: false) == nil)
    }

    @Test("the provider conforms to the neutral image-captioning capability")
    func providerCaptions() {
        #expect((MLXBrainProvider() as Any) is ImageCaptioning)
    }
}
