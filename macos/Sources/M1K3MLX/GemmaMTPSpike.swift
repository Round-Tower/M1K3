//
//  GemmaMTPSpike.swift
//  M1K3MLX
//
//  SPIKE (2026-07-19): can Big (gemma-4-12B) use MTP speculative decoding on
//  our pinned mlx-swift-lm 3.31.4? The lib ships the whole stack
//  (MTPSpeculativeTokenIterator + a Gemma4AssistantDraftModel), and
//  mlx-community publishes a 238MB 4-layer drafter built for our exact target
//  (gemma-4-12B-it-qat-assistant-4bit). Three questions, pre-registered:
//
//    1. LOADS — the drafter's model_type is `gemma4_unified_assistant`, which
//       3.31.4's Gemma4AssistantRegistration does NOT register (it only knows
//       `gemma4_assistant`). We alias-register it app-side with the same
//       creator. Does the config decode + 4-bit weights load?
//    2. ENGAGES + SPEEDS UP — accept rate and decode tok/s vs a same-prompt
//       baseline, through the MLXVLM load path (the ONLY Gemma4 that emits
//       `mtpLastHiddenStatesKey`; MLXLLM's text-only Gemma4 doesn't, so the
//       production load path would silently passthrough).
//    3. SURVIVES THE WRAP — gemma-4-12B has sliding_window=1024 and our
//       personas prefill past it. Post-wrap, RotatingKVCache reports
//       untrimmable and the iterator's rejected-token rewind no-ops
//       (MTPSpeculativeTokenIterator.swift:355-359) WITHOUT switching to
//       passthrough — rejected junk K/V stays in the ring. Under greedy
//       sampling speculative decoding must be byte-identical to baseline, so
//       the instrument is an exact-match diff across three window regimes:
//       short (never wraps), medium (wraps mid-decode), long (wrapped from
//       prefill). Divergence + degradation on the wrapped fixtures = the
//       pollution is real and the production integration must gate on prompt
//       length (or fix upstream).
//
//  Not wired into BrainTier/MLXBrainProvider. Isolated on purpose — same
//  doctrine as GemmaVisionSpike: "existence ≠ loadability ≠ quality. Verify
//  each stage."
//
//  Signed: Kev + claude-fable-5, 2026-07-19, Confidence 0.5 (spike; compiles,
//  on-device run pending — the wrapped-window question is exactly what the
//  run answers), Prior: Unknown
//  Review: claude-fable-5, 2026-07-19 — the on-device run HAPPENED same day
//  (scratch/mtp-spike/RESULTS.md): gates 1/6 PASS (alias registration works,
//  238MB drafter loads, 7789MB peak both-resident), gate 2 FAIL root-caused —
//  Gemma4Unified lacks the MTP-aware callAsFunction(_:cache:state:) override
//  (only legacy Gemma4 has it, Gemma4.swift:2092 @3.31.4; confirmed still
//  missing on upstream main). Every fixture sticky-passthroughs with "main
//  model did not emit drafter state", 0 drafted. Bonus finding: the iterator's
//  passthrough fallback is 0.13×-0.80× the plain generate path (synchronous
//  per-token eval) — never wire MTP without an engagement bail-out. Gate 4
//  (wrapped-window pollution) UNANSWERED until upstream fixes engagement; this
//  instrument re-runs as-is when it does. Confidence for the instrument: 0.9.
//

import Foundation
import MLXLMCommon
import MLXVLM

public enum GemmaMTPSpike {
    /// Production Big. `config.json` model_type is `gemma4_unified`, so the
    /// checkpoint routes natively through VLMModelFactory.
    public static let defaultTargetID = "mlx-community/gemma-4-12B-it-4bit"
    /// The paired 4-layer MTP drafter (238MB, 66M params, 4-bit).
    public static let defaultDrafterID = "mlx-community/gemma-4-12B-it-qat-assistant-4bit"

    public struct FixtureResult: Sendable {
        public let label: String
        public let promptTokens: Int
        public let baselineTokens: Int
        public let baselineTokensPerSecond: Double
        public let mtpTokens: Int
        public let mtpTokensPerSecond: Double
        public let proposedDraftTokens: Int?
        public let acceptedDraftTokens: Int?
        public let passthroughReason: String?
        /// Greedy speculative decoding must reproduce the greedy baseline
        /// byte-for-byte. `nil` means identical; a value is the character
        /// index of first divergence (the wrapped-window pollution signal).
        public let firstDivergenceIndex: Int?
        public let baselineAnswer: String
        public let mtpAnswer: String

        public var speedup: Double {
            baselineTokensPerSecond > 0 ? mtpTokensPerSecond / baselineTokensPerSecond : 0
        }

        public var acceptRate: Double? {
            guard let p = proposedDraftTokens, let a = acceptedDraftTokens, p > 0 else { return nil }
            return Double(a) / Double(p)
        }
    }

    public struct Result: Sendable {
        public let fixtures: [FixtureResult]
        public let ramSnapshot: String
    }

    public enum SpikeError: Error, Sendable {
        /// A stream finished without a `.info` event — no completion metadata,
        /// treat as probe failure, not a silent zero.
        case noCompletionInfo(String)
    }

    struct Fixture {
        let label: String
        let system: String?
        let prompt: String
        let maxTokens: Int
    }

    /// ~4 chars/token filler so the three fixtures land in their window
    /// regimes; actual prompt token counts are reported from the run.
    static func fixtures() -> [Fixture] {
        let personaFiller = String(
            repeating: "You keep answers grounded in the documents you were given and say so "
                + "plainly when you do not know. You prefer short, concrete sentences over "
                + "hedging. You never invent citations or file names. ",
            count: 55
        ) // ~55 × ~45 tokens ≈ 2.4k tokens — wrapped from prefill
        let mediumFiller = String(
            repeating: "The harbour logs arrive as plain text, one line per vessel movement, "
                + "with tide heights in metres and timestamps in local time. ",
            count: 22
        ) // ~22 × ~27 tokens ≈ 600 tokens — wraps mid-decode
        return [
            Fixture(
                label: "short-no-wrap",
                system: nil,
                prompt: "In one short sentence, what is a hydraulic seal?",
                maxTokens: 200
            ),
            Fixture(
                label: "medium-wraps-mid-decode",
                system: nil,
                prompt: mediumFiller
                    + "\n\nWrite a detailed multi-paragraph explanation of how you would "
                    + "parse these logs and summarise a day's traffic.",
                maxTokens: 700
            ),
            Fixture(
                label: "long-wrapped-at-prefill",
                system: personaFiller,
                prompt: "In two or three sentences, what do you do when you are not sure of an answer?",
                maxTokens: 300
            ),
        ]
    }

    /// Load target (MLXVLM path) + drafter, then run each fixture twice with
    /// greedy sampling: plain generate, then generate(mtpDrafter:). One
    /// container, fresh per-turn caches — mirrors the production per-turn
    /// session lifecycle.
    public static func run(
        targetID: String = defaultTargetID,
        drafterID: String = defaultDrafterID,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Result {
        // Upstream registration (gemma4_assistant) + the alias 3.31.4 lacks.
        // Same creator both ways; re-registration is idempotent.
        await Gemma4AssistantRegistration.register()
        await MTPDrafterTypeRegistry.shared.registerModelType("gemma4_unified_assistant") { data in
            let config = try JSONDecoder().decode(Gemma4AssistantConfiguration.self, from: data)
            return Gemma4AssistantDraftModel(config)
        }

        let configuration = VLMModelFactory.shared.configuration(id: targetID)
        let container = try await VLMModelFactory.shared.loadContainer(
            from: HubApiDownloader.llmDefault,
            using: TransformersTokenizerLoader(),
            configuration: configuration
        ) { prog in
            progress(prog.fractionCompleted)
        }

        // Greedy + the production repetition guard (identical LogitProcessor on
        // both legs keeps the exact-match instrument valid).
        var params = GenerateParameters()
        params.temperature = 0
        params.repetitionPenalty = 1.1
        params.repetitionContextSize = 64

        var results: [FixtureResult] = []
        for fixture in fixtures() {
            let perFixture: GenerateParameters = {
                var p = params
                p.maxTokens = fixture.maxTokens
                return p
            }()
            let result: FixtureResult = try await container.perform { context in
                // Drafter loaded INSIDE the target's isolation so the
                // non-Sendable MTPDrafterContext never crosses domains. The
                // factory caches nothing; the 238MB reload per fixture is the
                // price of spike-simple isolation. (First fixture downloads.)
                let drafter = try await MTPDrafterModelFactory.shared.load(
                    from: HubApiDownloader.llmDefault,
                    using: TransformersTokenizerLoader(),
                    configuration: ModelConfiguration(id: drafterID)
                )

                var chat: [Chat.Message] = []
                if let system = fixture.system { chat.append(.system(system)) }
                chat.append(.user(fixture.prompt))
                let input = try await context.processor.prepare(input: UserInput(chat: chat))

                // Baseline leg — fresh cache.
                let baseline = try await consume(
                    stream: MLXLMCommon.generate(
                        input: input,
                        cache: context.model.newCache(parameters: perFixture),
                        parameters: perFixture,
                        context: context
                    ),
                    label: fixture.label + "/baseline"
                )

                // MTP leg — fresh cache, same input, same params.
                let mtp = try await consume(
                    stream: MLXLMCommon.generate(
                        input: input,
                        cache: context.model.newCache(parameters: perFixture),
                        parameters: perFixture,
                        context: context,
                        mtpDrafter: drafter.model,
                        blockSize: 4
                    ),
                    label: fixture.label + "/mtp"
                )

                return FixtureResult(
                    label: fixture.label,
                    promptTokens: baseline.info.promptTokenCount,
                    baselineTokens: baseline.info.generationTokenCount,
                    baselineTokensPerSecond: baseline.info.tokensPerSecond,
                    mtpTokens: mtp.info.generationTokenCount,
                    mtpTokensPerSecond: mtp.info.tokensPerSecond,
                    proposedDraftTokens: mtp.info.proposedDraftTokens,
                    acceptedDraftTokens: mtp.info.acceptedDraftTokens,
                    passthroughReason: mtp.info.passthroughReason,
                    firstDivergenceIndex: firstDivergence(baseline.text, mtp.text),
                    baselineAnswer: baseline.text,
                    mtpAnswer: mtp.text
                )
            }
            results.append(result)
        }

        return Result(
            fixtures: results,
            ramSnapshot: MLXMemoryBudget.snapshotDescription(
                label: "MTP spike (VLM-loaded target + drafter resident)"
            )
        )
    }

    /// Drain a generation stream synchronously-in-order; text + the final
    /// `.info`. Tool calls can't occur (no tools in the prompt) but are
    /// tolerated as text-free events.
    private static func consume(
        stream: AsyncStream<Generation>, label: String
    ) async throws -> (text: String, info: GenerateCompletionInfo) {
        var text = ""
        var info: GenerateCompletionInfo?
        for await event in stream {
            switch event {
            case let .chunk(chunk): text += chunk
            case let .info(i): info = i
            default: break
            }
        }
        guard let info else { throw SpikeError.noCompletionInfo(label) }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), info)
    }

    /// Character index of the first difference, nil when identical after
    /// whitespace trimming (the greedy exact-match instrument).
    static func firstDivergence(_ a: String, _ b: String) -> Int? {
        if a == b { return nil }
        let aChars = Array(a), bChars = Array(b)
        for i in 0 ..< min(aChars.count, bChars.count) where aChars[i] != bChars[i] {
            return i
        }
        return min(aChars.count, bChars.count)
    }
}
