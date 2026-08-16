//
//  SwappableCapabilityForwardingTests.swift
//  M1K3InferenceTests
//
//  Every capability seam reached by `as?` must be forwarded by every façade,
//  or production (which holds a wrapper) silently diverges from any eval that
//  holds the bare provider — the #65 RecordingProvider lesson, re-found
//  2026-08-16 when the #117 persona dedup turned out to be dead through the
//  live RuntimeInferenceProvider (fixed-in-eval, broken-in-production), and
//  the grounding cap's tokenizer cast turned out to estimate on every tier.
//  These pin the package façade; the app's RuntimeInferenceProvider mirrors
//  each conformance by hand (compile-checked, verify-by-launch).
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.9, Prior: Unknown
//

import M1K3Inference
import Testing

private struct CountingProvider: TokenCounting {
    let name = "counting"
    let isAvailable = true
    func generate(prompt _: String) async throws -> String {
        "counted"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func tokenCount(_ text: String) async -> Int? {
        text.count
    }
}

private struct PlainProvider: InferenceProvider {
    let name = "plain"
    let isAvailable = true
    func generate(prompt _: String) async throws -> String {
        "plain"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

private struct CarryingProvider: InferenceProvider, PersonaCarrying {
    let name = "carrying"
    let isAvailable = true
    let carriesStandingPersona = true
    func generate(prompt _: String) async throws -> String {
        "carrying"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

struct SwappableCapabilityForwardingTests {
    @Test("token counting reaches the real tokenizer through the façade")
    func tokenCountingForwards() async {
        let facade = SwappableInferenceProvider(CountingProvider())
        #expect(await facade.tokenCount("hello") == 5)
    }

    @Test("a backend without a tokenizer reads nil through the façade — estimate, never skip")
    func tokenCountingNilForBare() async {
        let facade = SwappableInferenceProvider(PlainProvider())
        #expect(await facade.tokenCount("hello") == nil)
    }

    @Test("a swap re-points the tokenizer — counts follow the ACTIVE backend")
    func tokenCountingFollowsSwap() async {
        let facade = SwappableInferenceProvider(PlainProvider())
        #expect(await facade.tokenCount("hi") == nil)
        facade.setProvider(CountingProvider())
        #expect(await facade.tokenCount("hi") == 2)
    }

    @Test("persona carriage follows the active backend through the façade")
    func personaCarryingFollowsSwap() {
        let facade = SwappableInferenceProvider(CarryingProvider())
        #expect(facade.carriesStandingPersona)
        facade.setProvider(PlainProvider())
        #expect(!facade.carriesStandingPersona)
    }
}
