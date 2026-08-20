//
//  AppleFoundationModelsProviderTests.swift
//  M1K3InferenceTests
//
//  The AFM provider is an OS adapter — generate()/streaming hit Apple
//  Intelligence hardware, so they aren't exercised here. We pin the parts that
//  are deterministic: its identity and that it conforms to the router's seam.
//  `isAvailable` is read but not asserted (it depends on the host machine).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown

@testable import M1K3Inference
import Testing

struct AppleFoundationModelsProviderTests {
    @Test("has the expected stable name")
    func name() {
        #expect(AppleFoundationModelsProvider().name == "apple-foundation-models")
    }

    @Test("conforms to the InferenceProvider seam")
    func conformsToSeam() {
        // Reads availability without asserting a value (host-dependent), and
        // pins that the concrete type satisfies the protocol the runtime routes
        // against.
        let provider: any InferenceProvider = AppleFoundationModelsProvider()
        _ = provider.isAvailable
        #expect(provider.name == "apple-foundation-models")
    }

    @Test("native tool-calling is OFF by default — launch routing keeps the ReAct floor")
    func toolCallingDefaultsOff() {
        // The default-constructed provider must report no tool support regardless
        // of host availability, so LocalAgent never hands AFM the native loop
        // unless the spike is explicitly opted in.
        #expect(AppleFoundationModelsProvider().supportsToolCalls == false)
    }

    @Test("opting in gates tool support on host availability, not the flag alone")
    func toolCallingOptInGatesOnAvailability() {
        let provider = AppleFoundationModelsProvider(nativeToolCalling: true)
        // On CI (no Apple Intelligence hardware) both sides are false, so this
        // asserts false == false — it exercises the AND contract, not the `true`
        // branch (which needs Apple Intelligence). The point: never claim tool
        // support on an unavailable host, even with the opt-in flag set.
        #expect(provider.supportsToolCalls == provider.isAvailable)
    }

    @Test("the raw route's response cap holds — shorten, never lengthen (nil = the cap)")
    func rawResponseTokenClamp() {
        // The façade forwarding tests only prove maxTokens ARRIVES; this pins
        // the ceiling itself, because the request value is network-supplied
        // (Brain at Home /v1/generate — PR #139 review fold).
        let cap = AppleFoundationModelsProvider.rawResponseTokenCap
        #expect(AppleFoundationModelsProvider.clampedRawResponseTokens(nil) == cap)
        #expect(AppleFoundationModelsProvider.clampedRawResponseTokens(10_000_000) == cap)
        #expect(AppleFoundationModelsProvider.clampedRawResponseTokens(64) == 64)
        #expect(AppleFoundationModelsProvider.clampedRawResponseTokens(0) == 1)
        #expect(AppleFoundationModelsProvider.clampedRawResponseTokens(-5) == 1)
    }
}
