//
//  SeededPrefillProbe.swift
//  M1K3MLX
//
//  PROBE (2026-10-07): may a turn append to a SEEDED cache on Qwen3.5 and get the same
//  next token a full prefill would? The Lil shootout measured Qwen3.5's whole 3× tool-turn
//  gap as prefill (0/3232 tokens reused: its linear-attention layers hold a MambaCache, never
//  trimmable, so cross-turn reuse is vetoed). The fix is an exact seed: snapshot the persona +
//  palette prefill, append each turn's suffix. Before building it, prove that appending is
//  CORRECT on the load path Lil would use:
//
//    • MLXVLM's Qwen35 anchors M-RoPE positions on a warm cache through
//      `QwenVL.continuationAnchor`, which needs the rope delta carried in `LMOutput.State`
//      and THROWS (`missingState`) without it — a fresh `generate()` hands it `state: nil`.
//    • MLXLLM's Qwen35 reads the cache's own offset and needs no state (the control).
//
//  Three arms per load path, on one model: (1) full prefill, (2) prefix then suffix with
//  `state: nil` (what a seeded `generate()` does today), (3) prefix then suffix carrying the
//  prefix's returned state. Each seeded arm's last-position logits are judged against (1).
//  Two prompt lengths: one under the prefill window (single-shot cold path) and one over it
//  (the windowed continuation path the app's ~2.3k-token seed takes).
//
//  Not wired into the product. Weights come from the app's own store and are never
//  downloaded here: an absent model is reported, not fetched. Run it with
//  `M1K3_SELFTEST=1 M1K3_SELFTEST_SEEDPROBE=<model id>` (SelfTest's SeedProbeStage).
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.7 (the verdict, text and split are
//  TDD'd in SeededPrefillProbeTests; the MLX arms are verify-by-launch, metallib wall).
//  Prior: none (new file); shaped after GemmaVisionSpike.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

/// One seeded continuation's next-token logits, judged against a full prefill's.
public struct SeededPrefillVerdict: Sendable, Equatable {
    public let argmaxFull: Int
    public let argmaxSeeded: Int
    public let maxAbsDiff: Float
    public let tolerance: Float

    /// Same top token AND every logit within tolerance. Wrong positions move every logit;
    /// chunking and 4-bit arithmetic move them a little.
    public var consistent: Bool {
        argmaxFull == argmaxSeeded && maxAbsDiff <= tolerance
    }

    /// Generous for 4-bit weights and chunked-vs-single-shot arithmetic; the LLM control arm
    /// reports the drift a correct continuation actually shows, so the bar can be re-read.
    public static let defaultTolerance: Float = 1.0

    /// nil when the two can't be compared (empty, different vocabularies, non-finite):
    /// an unscorable probe must never read as a pass.
    public static func judge(
        full: [Float], seeded: [Float], tolerance: Float = defaultTolerance
    ) -> SeededPrefillVerdict? {
        guard !full.isEmpty, full.count == seeded.count,
              full.allSatisfy(\.isFinite), seeded.allSatisfy(\.isFinite)
        else { return nil }
        var drift: Float = 0
        for (a, b) in zip(full, seeded) {
            drift = max(drift, abs(a - b))
        }
        return SeededPrefillVerdict(
            argmaxFull: argmax(full), argmaxSeeded: argmax(seeded),
            maxAbsDiff: drift, tolerance: tolerance
        )
    }

    /// First index of the maximum, so a tie never reads as a flip.
    static func argmax(_ values: [Float]) -> Int {
        var best = 0
        for index in values.indices where values[index] > values[best] {
            best = index
        }
        return best
    }

    public var line: String {
        let drift = String(format: "%.3f", maxAbsDiff)
        return "\(consistent ? "CONSISTENT" : "DIVERGES") — top \(argmaxFull)/\(argmaxSeeded), "
            + "max |Δlogit| \(drift) (tolerance \(tolerance))"
    }
}

public enum SeededPrefillProbe {
    public enum LoadPath: String, Sendable, CaseIterable {
        case vlm, llm
    }

    public enum ProbeError: Error, Sendable {
        case notInstalled(String)
        case promptTooShort(tokens: Int)
    }

    public static let defaultModelID = "mlx-community/Qwen3.5-4B-MLX-4bit"
    static let suffixTokens = 24

    /// Distinct, deterministic lines: no exact repeats, so a wrong position can't coast on
    /// a copied n-gram. ~20 tokens a line.
    static func probeText(lines: Int) -> String {
        let parts = ["seal", "pump", "valve", "belt", "motor", "sensor", "bearing"]
        let states = ["held under load", "ran warm", "was replaced", "passed inspection", "slipped twice"]
        return (1 ... max(lines, 1)).map { i in
            "Log \(i): the \(parts[i % parts.count]) on conveyor \(i * 7 % 31) "
                + "\(states[i % states.count]) during shift \(i % 3 + 1)."
        }.joined(separator: "\n")
    }

    /// Where the seed ends: the last `suffix` tokens are the turn. nil when there's nothing
    /// worth seeding (the prefix must outweigh the suffix).
    static func splitPoint(tokenCount: Int, suffix: Int) -> Int? {
        guard suffix > 0, tokenCount > suffix * 2 else { return nil }
        return tokenCount - suffix
    }

    /// The three arms on one load path, for each prompt length. Lines are report-ready.
    public static func run(modelID: String, path: LoadPath, lineCounts: [Int] = [12, 130]) async throws -> [String] {
        guard LocalModelInventory().isInstalled(modelID: modelID) else {
            throw ProbeError.notInstalled(modelID)
        }
        let container: ModelContainer = switch path {
        case .vlm:
            try await VLMModelFactory.shared.loadContainer(
                from: HubApiDownloader.llmDefault, using: TransformersTokenizerLoader(),
                configuration: VLMModelFactory.shared.configuration(id: modelID)
            )
        case .llm:
            try await LLMModelFactory.shared.loadContainer(
                from: HubApiDownloader.llmDefault, using: TransformersTokenizerLoader(),
                configuration: LLMModelFactory.shared.configuration(id: modelID)
            )
        }
        defer { MLXMemoryBudget.reclaim(label: "seedprobe-\(path.rawValue)") }
        var lines: [String] = []
        for count in lineCounts {
            lines += try await container.perform { context in
                try arms(context: context, text: probeText(lines: count), path: path)
            }
        }
        return lines
    }

    private static func arms(context: ModelContext, text: String, path: LoadPath) throws -> [String] {
        let model = context.model
        let ids = context.tokenizer.encode(text: text)
        guard let split = splitPoint(tokenCount: ids.count, suffix: suffixTokens) else {
            throw ProbeError.promptTooShort(tokens: ids.count)
        }
        let head = "seedprobe \(path.rawValue) prompt=\(ids.count) seed=\(split) suffix=\(ids.count - split)"
        let full = try forward(model, ids[...], cache: model.newCache(parameters: nil), state: nil).logits

        // (2) What a seeded `generate()` does today: a fresh call, `state: nil`.
        let bare = try model.newCache(parameters: nil)
        _ = try forward(model, ids[..<split], cache: bare, state: nil)
        let bareLine: String
        do {
            let seeded = try forward(model, ids[split...], cache: bare, state: nil).logits
            bareLine = SeededPrefillVerdict.judge(full: full, seeded: seeded)?.line ?? "UNSCORABLE"
        } catch {
            bareLine = "THREW \(error)"
        }

        // (3) The prefix's returned state carried into the suffix.
        let carried = try model.newCache(parameters: nil)
        let prefix = try forward(model, ids[..<split], cache: carried, state: nil)
        let carriedLine: String
        do {
            let seeded = try forward(model, ids[split...], cache: carried, state: prefix.state).logits
            carriedLine = SeededPrefillVerdict.judge(full: full, seeded: seeded)?.line ?? "UNSCORABLE"
        } catch {
            carriedLine = "THREW \(error)"
        }
        return [
            "\(head) | state=nil: \(bareLine)",
            "\(head) | state=carried(\(prefix.state == nil ? "none returned" : "present")): \(carriedLine)",
        ]
    }

    /// One prefill the way `TokenIterator` starts a turn (`prepare`, then the remainder
    /// as a step), returning the last position's logits as floats and the state it handed back.
    private static func forward(
        _ model: any LanguageModel, _ ids: ArraySlice<Int>, cache: [KVCache], state: LMOutput.State?
    ) throws -> (logits: [Float], state: LMOutput.State?) {
        let input = LMInput(tokens: MLXArray(ids.map { Int32($0) }))
        let output: LMOutput = switch try model.prepare(input, cache: cache, state: state, prefill: PrefillParameters()) {
        case let .logits(result):
            result
        case let .tokens(rest):
            model(rest[text: .newAxis], cache: cache, state: state)
        }
        let last = output.logits[0, -1].asType(.float32)
        eval(last)
        return (last.asArray(Float.self), output.state)
    }
}
