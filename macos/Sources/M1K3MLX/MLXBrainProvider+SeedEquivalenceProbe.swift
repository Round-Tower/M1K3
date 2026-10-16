//
//  MLXBrainProvider+SeedEquivalenceProbe.swift
//  M1K3MLX
//
//  The real-model proof behind reusing a persona seed that wrapped a sliding
//  window (gemma-4: a ~1,878-token persona against 1,024-token sliding layers).
//  `personaPrefixInvariantProbe` proves the TOKENS line up; this proves the
//  MATHS does: for each prompt, the last-position logits and a greedy decode
//  from (A) one fresh prefill of the whole render and (B) the seed prefilled
//  exactly, deep-copied, then extended by the suffix — the plain turn's
//  SeededPlainTurn.reuse path. Chunk boundaries differ between the arms, so bf16
//  rounding does too, so a CONTROL arm (C) prefills fresh again at another chunk
//  size: two arms that are both right. The seed passes when it agrees with A on
//  the top token and on as many greedy tokens as the control does (capped at
//  `greedyMustMatch`), with both logit gaps reported, never `==` (challenger).
//
//  Run: `M1K3_SELFTEST=1 M1K3_SELFTEST_SEEDEQ=1 M1K3_SELFTEST_MODEL=big`, also with
//  `-prefillStepSize 333` so the seed ends on the single-token in-place write.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-16, Confidence 0.7 (compiles against the
//  pinned mlx-swift-lm; the verdict is whatever the run reports). Prior: Unknown.

import Foundation
import M1K3Inference
import MLX
import MLXLMCommon

extension MLXBrainProvider {
    /// Greedy tokens each arm decodes; the first `greedyMustMatch` must agree.
    static let seedProbeGreedyTokens = 24
    static let greedyMustMatch = 16

    public func wrappedSeedEquivalenceProbe() async -> String {
        let container: ModelContainer
        do {
            container = try await ensureLoaded()
        } catch {
            return "seed equivalence: load failed — \(error)"
        }
        let persona = M1K3Persona.systemPrompt(variant: personaVariant)
        let window = Self.slidingWindow(forModelID: modelIdentifier, configDirectory: configDirectory)
        // Suffixes of a few tokens, a few hundred, and past the window (two prefill chunks).
        let long = Array(repeating: "Tell me about the coast road from Cork to Kinsale, every village on it.", count: 90)
            .joined(separator: " ")
        let prompts = ["hi", "What's the weather in Cork today?", long]
        var lines = ["seed equivalence (window \(window.map(String.init) ?? "none")):"]
        var passed = 0
        for (index, prompt) in prompts.enumerated() {
            let line = await compareArms(container: container, persona: persona, prompt: prompt)
            if line.hasPrefix("PASS") { passed += 1 }
            lines.append("  [\(index)] \(line)")
        }
        lines.append("  → \(passed)/\(prompts.count) PASS")
        return lines.joined(separator: "\n")
    }

    private func compareArms(container: ModelContainer, persona: String, prompt: String) async -> String {
        let parameters = generateParameters
        do {
            return try await container.perform { context in
                guard let upstream = (context.tokenizer as? TransformersTokenizerAdapter)?.upstream else {
                    return "ERROR no template tokenizer"
                }
                let seedInputs = MLXToolMapping.seedInputs(
                    persona: persona, specs: nil, format: self.resolvedToolCallFormat ?? .json
                )
                let messages: [[String: String]] = [
                    ["role": "system", "content": seedInputs.system], ["role": "user", "content": prompt],
                ]
                let full = try upstream.applyChatTemplate(
                    messages: messages, chatTemplate: nil, addGenerationPrompt: true,
                    truncation: false, maxLength: nil, tools: nil
                )
                let seed = try self.systemBlockIDs(context: context, persona: persona, specs: nil)
                guard full.count > seed.count + 1, full.starts(with: seed) else {
                    return "ERROR seed is not a prefix of the render (seed \(seed.count), full \(full.count))"
                }
                let model = context.model

                // A: one fresh prefill of everything but the last token, then the last token.
                let fresh = try model.newCache(parameters: parameters)
                try Self.prefillExactly(Array(full.dropLast()), into: fresh, state: nil, parameters: parameters, model: model)

                // B: the seed exactly, a deep copy (as PersonaPrefixCache hands out), then the suffix.
                let seedCache = try model.newCache(parameters: parameters)
                try Self.prefillExactly(seed, into: seedCache, state: nil, parameters: parameters, model: model)
                let wrapped = seedCache.contains { !$0.isTrimmable }
                let seeded = seedCache.map { $0.copy() }
                let suffix = Array(full[seed.count ..< (full.count - 1)])
                if !suffix.isEmpty {
                    try Self.prefillExactly(suffix, into: seeded, state: nil, parameters: parameters, model: model)
                }

                // C, the control: fresh again at another chunk size (both A and C are right).
                var controlParameters = parameters
                controlParameters.prefill = .init(stepSize: Self.controlStepSize)
                let control = try model.newCache(parameters: controlParameters)
                try Self.prefillExactly(
                    Array(full.dropLast()), into: control, state: nil, parameters: controlParameters, model: model
                )

                let last = full[full.count - 1]
                let logitsA = Self.step(last, cache: fresh, model: model)
                let logitsB = Self.step(last, cache: seeded, model: model)
                let logitsC = Self.step(last, cache: control, model: model)
                let gapB = Self.maxGap(logitsA, logitsB), gapC = Self.maxGap(logitsA, logitsC)
                let greedyA = Self.greedy(from: logitsA, cache: fresh, model: model)
                let greedyB = Self.greedy(from: logitsB, cache: seeded, model: model)
                let greedyC = Self.greedy(from: logitsC, cache: control, model: model)
                let agreeB = zip(greedyA, greedyB).prefix { $0 == $1 }.count
                let agreeC = zip(greedyA, greedyC).prefix { $0 == $1 }.count
                let sameTop = greedyA.first == greedyB.first
                let pass = sameTop && agreeB >= min(Self.greedyMustMatch, agreeC)
                let text = context.tokenizer.decode(tokenIds: greedyB).replacingOccurrences(of: "\n", with: " ")
                return "\(pass ? "PASS" : "FAIL") seed=\(seed.count) suffix=\(suffix.count + 1) wrapped=\(wrapped) "
                    + "seed: maxΔ=\(String(format: "%.3f", gapB)) greedy=\(agreeB)/\(Self.seedProbeGreedyTokens) · "
                    + "control: maxΔ=\(String(format: "%.3f", gapC)) greedy=\(agreeC)/\(Self.seedProbeGreedyTokens) "
                    + "top1=\(sameTop) «\(text.prefix(50))»"
            }
        } catch {
            return "ERROR \(String(describing: error).prefix(120))"
        }
    }

    /// The control arm's chunk size: off the default grid on purpose.
    static let controlStepSize = 257

    private static func maxGap(_ a: MLXArray, _ b: MLXArray) -> Float {
        abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
    }

    /// Greedy tokens from these logits on, extending `cache`.
    private static func greedy(from logits: MLXArray, cache: [KVCache], model: any LanguageModel) -> [Int] {
        var token = argMax(logits, axis: -1).item(Int.self)
        var tokens = [token]
        for _ in 1 ..< seedProbeGreedyTokens {
            token = argMax(step(token, cache: cache, model: model), axis: -1).item(Int.self)
            tokens.append(token)
        }
        return tokens
    }

    /// One token through the model; the last position's logits.
    private static func step(_ token: Int, cache: [KVCache], model: any LanguageModel) -> MLXArray {
        let text = LMInput.Text(tokens: MLXArray([token]))
        let output = model(text[text: .newAxis], cache: cache, state: nil)
        let logits = output.logits[0, -1]
        eval(logits)
        return logits
    }
}
