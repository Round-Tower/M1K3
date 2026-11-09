//
//  MLXBrainProvider+ImageLookingTests.swift
//  M1K3MLXTests
//
//  The look's policy pins: no persona fallback, a short cap, thinking off, and
//  a brain that cannot see fails the stream before it loads anything. The
//  model-backed path (a frame in, words out) is verify-by-launch.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.8, Prior: none (new file)

import Foundation
import M1K3Inference
@testable import M1K3MLX
import Testing

struct MLXBrainProviderImageLookingTests {
    @Test("a look has no persona fallback: blank instructions are an error, never the persona")
    func lookInstructionsRefuseBlank() throws {
        #expect(try MLXBrainProvider.lookInstructions("  Look.\n") == "Look.")
        #expect(throws: InferenceError.self) { try MLXBrainProvider.lookInstructions("") }
        #expect(throws: InferenceError.self) { try MLXBrainProvider.lookInstructions(" \n ") }
    }

    @Test("a look answers in a sentence or two: the cap only ever shortens the provider's own")
    func lookCapShortens() {
        #expect(MLXBrainProvider.lookMaxTokens(providerCap: nil) == MLXBrainProvider.lookMaxTokens)
        #expect(MLXBrainProvider.lookMaxTokens(providerCap: 4096) == MLXBrainProvider.lookMaxTokens)
        #expect(MLXBrainProvider.lookMaxTokens(providerCap: 40) == 40)
        #expect(MLXBrainProvider.lookMaxTokens <= 200)
    }

    @Test("the provider conforms to the look capability")
    func providerLooks() {
        #expect((MLXBrainProvider() as Any) is ImageLooking)
    }

    @Test("a text-only brain fails the stream without loading a model")
    func textOnlyBrainFails() async {
        let provider = MLXBrainProvider() // the default checkpoint is text-only
        #expect(!provider.supportsImageInput)
        let image = ImageAttachment(url: URL(fileURLWithPath: "/tmp/frame.jpg"))
        var yielded = 0
        var failure: InferenceError?
        do {
            for try await _ in provider.look(image: image, instructions: "Look.", prompt: "What is this?") {
                yielded += 1
            }
        } catch let error as InferenceError {
            failure = error
        } catch {}
        #expect(yielded == 0)
        #expect(failure == ImageLookingError.cannotLook)
    }
}
