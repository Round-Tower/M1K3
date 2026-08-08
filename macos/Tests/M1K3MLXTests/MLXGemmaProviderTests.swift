//
//  MLXGemmaProviderTests.swift
//  M1K3MLXTests
//
//  Fast tier: protocol conformance + availability, no model load. Integration
//  tier (M1K3_MLX_INTEGRATION=1): actually downloads Gemma and generates — the
//  first real proof the MLXLLM path works end-to-end. Network + minutes.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.75, Prior: Unknown

import Foundation
import M1K3Chat
import M1K3Inference
@testable import M1K3MLX
import MLXLMCommon
import Testing

struct MLXGemmaProviderTests {
    @Test("conforms to InferenceProvider and is available on this target")
    func conformanceAndAvailability() {
        let provider: any InferenceProvider = MLXGemmaProvider()
        #expect(provider.name == "mlx-gemma")
        #expect(provider.isAvailable)
    }

    @Test("the provider's default generation ceiling matches HistoryBudgetPolicy's defaultCap (116-F1)")
    func defaultGenerationCeilingMatchesBudgetPolicy() {
        // The 4096 figure lives on BOTH sides of the Chat↔MLX boundary: the
        // policy's generationTokenCap(defaultCap:) mirrors this class's default.
        // If either moves alone, the window math silently models a value the
        // live provider never uses — this pin makes the drift loud.
        #expect(HistoryBudgetPolicy.generationTokenCap(for: .lil) == MLXGemmaProvider.defaultMaxTokens)
        // And the rotating cap must stay UNDER the default (a cap that exceeds
        // the ceiling would be a no-op).
        #expect(HistoryBudgetPolicy.rotatingGenerationTokenCap < MLXGemmaProvider.defaultMaxTokens)
    }

    @Test("gemma-4 owns its KV geometry — no caller capacity is requested for it")
    func callerKVCapacityFamilyResolution() {
        // Gemma4Text.newCache IGNORES `parameters` entirely: it builds
        // StandardKVCache for full_attention layers and a modelNative
        // RotatingKVCache(slidingWindow) for the rest. Requesting a capacity
        // was therefore always a silent no-op — and since mlx-swift-lm's
        // typed KV cache validation (#453, 2026-08-05) it is a hard throw
        // (`incompatibleCapacity(expected: 8192, count: 8)` — the 8 full
        // attention layers), which took gemma-4 tool-use from 5/5 to 0/5.
        #expect(!MLXGemmaProvider.supportsCallerKVCapacity(
            for: ModelConfiguration(id: "mlx-community/gemma-4-12B-it-4bit")
        ))
        #expect(!MLXGemmaProvider.supportsCallerKVCapacity(
            for: ModelConfiguration(id: "mlx-community/gemma-4-e4b-it-4bit")
        ))
        // Gemma3n likewise builds its own per-layer geometry.
        #expect(!MLXGemmaProvider.supportsCallerKVCapacity(
            for: ModelConfiguration(id: "mlx-community/gemma-3n-E4B-it-lm-4bit")
        ))
        // Everything on upstream's DEFAULT newCache honours a requested
        // capacity (it builds RotatingKVCache(.requested) per layer), so the
        // growth backstop stays real for them.
        #expect(MLXGemmaProvider.supportsCallerKVCapacity(
            for: ModelConfiguration(id: "mlx-community/Llama-3.2-1B-Instruct-4bit")
        ))
        #expect(MLXGemmaProvider.supportsCallerKVCapacity(
            for: ModelConfiguration(id: "mlx-community/some-unknown-model-4bit")
        ))
    }

    @Test("a gemma-4 provider requests neither quantized KV nor a caller capacity")
    func gemma4RequestsNoCacheOverrides() {
        let provider = MLXGemmaProvider(
            configuration: ModelConfiguration(id: "mlx-community/gemma-4-12B-it-4bit")
        )
        // Both nil: quantized KV is unsafe for this family (raw cache.update)
        // and a capacity is rejected by upstream validation.
        #expect(provider.generateParameters.maxKVSize == nil)
        #expect(provider.generateParameters.kvBits == nil)
    }

    @Test("KV quantization is allow-listed per family — raw cache.update families are excluded")
    func kvQuantizationFamilyResolution() {
        // Safe: attention routes through upstream's attentionWithCacheUpdate
        // dispatcher, which handles QuantizedKVCache via updateQuantized.
        #expect(MLXGemmaProvider.supportsQuantizedKVCache(
            for: ModelConfiguration(id: "mlx-community/Qwen3.5-2B-4bit")
        ))
        #expect(MLXGemmaProvider.supportsQuantizedKVCache(
            for: ModelConfiguration(id: "mlx-community/Qwen3.5-9B-4bit")
        ))
        #expect(MLXGemmaProvider.supportsQuantizedKVCache(
            for: ModelConfiguration(id: "mlx-community/gemma-3-1b-it-qat-4bit")
        ))
        // Unsafe: Gemma3nText/Gemma4Text call cache.update(keys:values:) raw,
        // which is an upstream fatalError on a quantized cache.
        #expect(!MLXGemmaProvider.supportsQuantizedKVCache(
            for: ModelConfiguration(id: "mlx-community/gemma-4-e4b-it-4bit")
        ))
        #expect(!MLXGemmaProvider.supportsQuantizedKVCache(
            for: ModelConfiguration(id: "mlx-community/gemma-3n-E4B-it-lm-4bit")
        ))
        // Unknown families default to NOT quantizing — crash-safe over fast.
        #expect(!MLXGemmaProvider.supportsQuantizedKVCache(
            for: ModelConfiguration(id: "some/unknown-model")
        ))
        // The WIRED dense tier (lil): Qwen3 attention routes through
        // upstream's attentionWithCacheUpdate dispatcher (Qwen3.swift:84), which
        // handles QuantizedKVCache — unlike Gemma4Text's raw cache.update. So
        // quantized KV is SAFE for dense Qwen3 (verified vs mlx-swift-lm 3.31.3).
        #expect(MLXGemmaProvider.supportsQuantizedKVCache(
            for: ModelConfiguration(id: "mlx-community/Qwen3-4B-4bit")
        ))
        #expect(MLXGemmaProvider.supportsQuantizedKVCache(
            for: ModelConfiguration(id: "mlx-community/Qwen3-8B-4bit")
        ))
        // Ternary Bonsai 8B IS dense Qwen3 under the brand (model_type "qwen3" →
        // Qwen3Model → attentionWithCacheUpdate), so quantized KV is safe.
        #expect(MLXGemmaProvider.supportsQuantizedKVCache(
            for: ModelConfiguration(id: "prism-ml/Ternary-Bonsai-8B-mlx-2bit")
        ))
        // Bonsai-27B is qwen3_5 under a brand id (config verified 2026-07-17).
        // The family's full-attention layers route through upstream's
        // attentionWithCacheUpdate dispatcher (Qwen35.swift:367, re-audited at
        // mlx-swift-lm 3.31.4) and quantized KV ran in production on the same
        // arch when lil was Qwen3.5-4B — safe, so the old unverified-default
        // exclusion lifts.
        #expect(MLXGemmaProvider.supportsQuantizedKVCache(
            for: ModelConfiguration(id: "prism-ml/Ternary-Bonsai-27B-mlx-2bit")
        ))
    }

    @Test("Bonsai thinking toggle per size: the 8B template has no enable_thinking, the 27B's reads it")
    func bonsaiThinkingTogglePerSize() {
        // Unlike stock Qwen3, prism-ml's Bonsai chat template carries no
        // enable_thinking switch (verified against the HF template 2026-07-15) —
        // claiming toggle support would render a kwarg the template ignores and
        // silently break fast mode's expectations. Pin it off.
        #expect(!MLXGemmaProvider.templateSupportsThinkingToggle(
            for: ModelConfiguration(id: "prism-ml/Ternary-Bonsai-8B-mlx-2bit")
        ))
        // The 27B DIFFERS: its qwen3_5 template reads enable_thinking (verified
        // against the HF chat_template.jinja 2026-07-17) — so it claims the
        // toggle and the reasoning picker stays a live control on this brain.
        #expect(MLXGemmaProvider.templateSupportsThinkingToggle(
            for: ModelConfiguration(id: "prism-ml/Ternary-Bonsai-27B-mlx-2bit")
        ))
    }

    @Test("the 2507 line does NOT claim the thinking toggle — Instruct never thinks, Thinking always does")
    func qwen2507ThinkingTogglePinnedOff() {
        // Qwen split the 2507 refresh into two FIXED-mode variants; neither
        // template carries enable_thinking (verified against the HF template
        // 2026-07-16). The bare "qwen3" name-match would claim the toggle and
        // leave the Settings reasoning picker as a control that does nothing —
        // the dead-control rule says pin it off instead. THE WIRED LIL (since
        // 2026-07-16) is the Instruct variant, so this pin is load-bearing.
        #expect(!MLXGemmaProvider.templateSupportsThinkingToggle(
            for: ModelConfiguration(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        ))
        #expect(!MLXGemmaProvider.templateSupportsThinkingToggle(
            for: ModelConfiguration(id: "mlx-community/Qwen3-4B-Thinking-2507-4bit")
        ))
        // Stock (pre-2507) Qwen3 keeps the toggle — the exclusion must not
        // over-reach.
        #expect(MLXGemmaProvider.templateSupportsThinkingToggle(
            for: ModelConfiguration(id: "mlx-community/Qwen3-4B-4bit")
        ))
        // And the 2507 line still rides the rest of the qwen3 family arms.
        #expect(MLXGemmaProvider.supportsQuantizedKVCache(
            for: ModelConfiguration(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        ))
        #expect(MLXGemmaProvider.resolveToolCallFormat(
            for: ModelConfiguration(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        ) == .json)
    }

    @Test("tool-turn thinking is decided per-turn, never from construction-time state")
    func toolTurnThinkingIsPerTurn() {
        // A toggle family that ALSO pre-opens (Qwen3.5): thinking ON ⇒ no
        // enable_thinking suppression + a pre-opened <think>; OFF ⇒
        // enable_thinking:false + no pre-open.
        let thinkOn = MLXGemmaProvider.toolTurnThinkingDecision(
            turnThinking: true, supportsToggle: true, preOpensThink: true
        )
        #expect(thinkOn.context == nil)
        #expect(thinkOn.prefixNeeded)

        let thinkOff = MLXGemmaProvider.toolTurnThinkingDecision(
            turnThinking: false, supportsToggle: true, preOpensThink: true
        )
        #expect(thinkOff.context?["enable_thinking"] as? Bool == false)
        #expect(!thinkOff.prefixNeeded)

        // THE FIX — dense Qwen3 (lil): toggles enable_thinking but does NOT
        // pre-open. Fast mode MUST suppress (enable_thinking:false), and a thinking
        // turn must NOT add a synthetic opener (the model emits its own <think>).
        let denseFast = MLXGemmaProvider.toolTurnThinkingDecision(
            turnThinking: false, supportsToggle: true, preOpensThink: false
        )
        #expect(denseFast.context?["enable_thinking"] as? Bool == false)
        #expect(!denseFast.prefixNeeded)

        let denseThink = MLXGemmaProvider.toolTurnThinkingDecision(
            turnThinking: true, supportsToggle: true, preOpensThink: false
        )
        #expect(denseThink.context == nil)
        #expect(!denseThink.prefixNeeded)

        // A non-toggle family (gemma) never suppresses and never pre-opens.
        let noToggleOn = MLXGemmaProvider.toolTurnThinkingDecision(
            turnThinking: true, supportsToggle: false, preOpensThink: false
        )
        #expect(noToggleOn.context == nil)
        #expect(!noToggleOn.prefixNeeded)

        let noToggleOff = MLXGemmaProvider.toolTurnThinkingDecision(
            turnThinking: false, supportsToggle: false, preOpensThink: false
        )
        #expect(noToggleOff.context == nil)
        #expect(!noToggleOff.prefixNeeded)
    }

    @Test("repetition penalty is mild and windowed — the degenerate-loop guard")
    func repetitionPenaltyPinned() {
        // 1.1 with a 64-token window suppresses verbatim loops without
        // distorting tool-call JSON or citation tokens (each repeats little
        // within 64 tokens). A silent edit toward ≥1.2 — where structured
        // output measurably degrades — should fail here, not at ⌘R.
        let provider = MLXGemmaProvider()
        #expect(provider.generateParameters.repetitionPenalty == 1.1)
        #expect(provider.generateParameters.repetitionContextSize == 64)
    }

    @Test("quantizing families carry kvBits; default-newCache families keep the rotation cap")
    func generateParametersPerFamily() {
        let qwen = MLXGemmaProvider(configuration: ModelConfiguration(id: "mlx-community/Qwen3.5-2B-4bit"))
        #expect(qwen.generateParameters.kvBits == 8)
        #expect(qwen.generateParameters.kvGroupSize == 64)
        #expect(qwen.generateParameters.quantizedKVStart == 0)
        #expect(qwen.generateParameters.maxKVSize == nil)

        // gemma-4 gets NEITHER: quantized KV is unsafe (raw cache.update) and
        // a caller capacity is meaningless (its newCache ignores parameters).
        // This assertion used to read `maxKVSize == 8192` — pinning a bound
        // the model never honoured. See supportsCallerKVCapacity.
        let gemma4 = MLXGemmaProvider(configuration: ModelConfiguration(id: "mlx-community/gemma-4-e4b-it-4bit"))
        #expect(gemma4.generateParameters.kvBits == nil)
        #expect(gemma4.generateParameters.maxKVSize == nil)

        // A family on upstream's default newCache still gets the real backstop.
        let llama = MLXGemmaProvider(
            configuration: ModelConfiguration(id: "mlx-community/Llama-3.2-1B-Instruct-4bit")
        )
        #expect(llama.generateParameters.maxKVSize == 8192)
    }

    @Test(
        "INTEGRATION: generates a non-empty response from a real Gemma",
        .enabled(if: ProcessInfo.processInfo.environment["M1K3_MLX_INTEGRATION"] == "1")
    )
    func generatesRealText() async throws {
        let provider = MLXGemmaProvider(maxTokens: 64)
        let answer = try await provider.generate(prompt: "Reply with exactly one short sentence about seals.")
        #expect(!answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test(
        "INTEGRATION: streams delta chunks that accumulate to a non-empty answer",
        .enabled(if: ProcessInfo.processInfo.environment["M1K3_MLX_INTEGRATION"] == "1")
    )
    func streamsRealText() async {
        let provider = MLXGemmaProvider(maxTokens: 64)
        var collected = ""
        for await chunk in provider.generateStreaming(prompt: "Say hello in one word.") {
            collected += chunk
        }
        #expect(!collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("VLM load path is exact-id allow-listed — only checkpoints PROVEN to load under MLXVLM")
    func vlmLoadPathResolution() {
        // gemma-4-12B loads under MLXVLM with the vision tower resident —
        // proven on-device twice (GemmaVisionSpike 2026-07-14: 7333MB peak;
        // GemmaMTPSpike 2026-07-19: 7789MB peak with a drafter beside it) and
        // text behaviour through the VLM container proven by three greedy
        // fixtures. The VLM path is what unlocks image input AND the MTP
        // drafter state emission (once upstream wires Gemma4Unified).
        #expect(MLXGemmaProvider.usesVLMLoadPath(
            for: ModelConfiguration(id: "mlx-community/gemma-4-12B-it-4bit")
        ))
        // e4b is NOT routable to MLXVLM: keyNotFound layers.24.self_attn.v_proj
        // (upstream's Gemma4Unified sanitize lacks the KV-shared-layer fix;
        // e4b has 18 shared layers, 12B has 0 — GemmaVisionSpike review,
        // 2026-07-14). Family-wide routing would brick the fallback tier.
        #expect(!MLXGemmaProvider.usesVLMLoadPath(
            for: ModelConfiguration(id: "mlx-community/gemma-4-e4b-it-4bit")
        ))
        // Text-only families stay on the LLM factory untouched.
        #expect(!MLXGemmaProvider.usesVLMLoadPath(
            for: ModelConfiguration(id: "mlx-community/gemma-3-1b-it-qat-4bit")
        ))
        #expect(!MLXGemmaProvider.usesVLMLoadPath(
            for: ModelConfiguration(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        ))
        #expect(!MLXGemmaProvider.usesVLMLoadPath(
            for: ModelConfiguration(id: "prism-ml/Ternary-Bonsai-8B-2bit-mlx")
        ))
        // Unknown ids default to the LLM factory — the known-good path.
        #expect(!MLXGemmaProvider.usesVLMLoadPath(
            for: ModelConfiguration(id: "someorg/some-future-model-4bit")
        ))
    }

    @Test("the provider's live vision flag agrees with the load-path routing")
    func providerVisionFlagMatchesRouting() {
        // supportsImageInput is what actually gates images into the chat
        // render (imagesAllowed) — pin the thin wrapper, not just the static.
        #expect(MLXGemmaProvider(modelID: "mlx-community/gemma-4-12B-it-4bit").supportsImageInput)
        #expect(!MLXGemmaProvider(modelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit").supportsImageInput)
    }

    @Test("BrainTier.supportsImageInput can never drift from the VLM load-path allow-list")
    func tierVisionFlagMatchesLoadPath() {
        // Two sources of truth by construction (BrainTier is dependency-free,
        // the allow-list lives beside the factories) — this pin makes a future
        // Big model swap fail LOUDLY here instead of shipping an attach button
        // for a brain that can't see. Review fold, PR #62.
        for tier in BrainTier.allCases {
            guard let modelID = tier.mlxModelID else {
                #expect(!tier.supportsImageInput)
                continue
            }
            #expect(
                tier.supportsImageInput
                    == MLXGemmaProvider.usesVLMLoadPath(for: ModelConfiguration(id: modelID))
            )
        }
    }
}
