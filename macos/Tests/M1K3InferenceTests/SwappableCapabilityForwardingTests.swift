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
//  Review: Kev + claude-opus-5, 2026-09-12, Confidence 0.85 — `promptLayoutFollowsSwap`: prompt shape and the
//  exemplar set are forwarded through the façade and follow a swap (the app façade had dropped `nativePromptShape`).
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

private struct LayoutProvider: ToolCallingProvider {
    let name = "layout"
    let isAvailable = true
    let supportsToolCalls = true
    let nativePromptShape: NativePromptShape
    let personaExemplars: PersonaExemplars
    func generate(prompt _: String) async throws -> String {
        "layout"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func continueToolTurn(messages _: [ToolMessage], tools _: [ToolDefinition]) async throws -> ToolTurn {
        .text("layout")
    }
}

private struct RawProvider: InferenceProvider, RawCompletionProviding {
    let name = "raw"
    let isAvailable = true
    func generate(prompt _: String) async throws -> String {
        "raw"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func generateRawStreaming(prompt: String, maxTokens: Int?) -> AsyncStream<String>? {
        AsyncStream { continuation in
            continuation.yield("raw:\(prompt):\(maxTokens.map(String.init) ?? "nil")")
            continuation.finish()
        }
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

    @Test("prompt shape and exemplar set follow the active backend through the façade (2026-09-12)")
    func promptLayoutFollowsSwap() {
        // The agent reads both off the provider it HOLDS; a façade that drops
        // them hands every model the defaults (the #133/#134 lesson).
        let pocket = LayoutProvider(nativePromptShape: .groundingInSystem, personaExemplars: .voiceAndLeakDecline)
        let facade = SwappableInferenceProvider(pocket)
        #expect(facade.nativePromptShape == .groundingInSystem)
        #expect(facade.personaExemplars == .voiceAndLeakDecline)
        facade.setProvider(PlainProvider())
        #expect(facade.nativePromptShape == .groundingInUser)
        #expect(facade.personaExemplars == .voice)
    }

    @Test("persona carriage follows the active backend through the façade")
    func personaCarryingFollowsSwap() {
        let facade = SwappableInferenceProvider(CarryingProvider())
        #expect(facade.carriesStandingPersona)
        facade.setProvider(PlainProvider())
        #expect(!facade.carriesStandingPersona)
    }

    @Test("raw completion reaches the real backend through the façade, maxTokens intact")
    func rawCompletionForwards() async throws {
        let facade = SwappableInferenceProvider(RawProvider())
        let stream = try #require(facade.generateRawStreaming(prompt: "hi", maxTokens: 64))
        var collected: [String] = []
        for await chunk in stream {
            collected.append(chunk)
        }
        #expect(collected == ["raw:hi:64"])
    }

    @Test("a backend without raw completion reads nil through the façade — a 503, never a persona-seeded fallback")
    func rawCompletionNilForBare() {
        let facade = SwappableInferenceProvider(PlainProvider())
        #expect(facade.generateRawStreaming(prompt: "hi", maxTokens: nil) == nil)
    }
}
