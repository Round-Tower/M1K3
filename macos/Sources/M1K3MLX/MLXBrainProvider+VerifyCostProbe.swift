//
//  MLXBrainProvider+VerifyCostProbe.swift
//  M1K3MLX
//
//  The one number the speculative-decoding verdict rests on, read off the real
//  brain in the real app: what a forward pass over T new tokens costs against
//  one token, on top of a cached prefix. A drafter (MTP, a small model, an
//  n-gram match) only pays when verifying its T guesses costs much less than T
//  single steps. docs/LONG_CONTEXT_AND_SPEED_DESIGN.md §2d/2e recorded 2 tokens
//  = 1.86× one on this M1 Max (2026-09-26, a Python rig that is gone), which
//  caps even a perfect drafter near 1.07×.
//
//  This is the measurement only: no drafter, nothing shipped, and no rollback of
//  a rejected draft (Lil's cache cannot roll back at all). Each timing is one
//  forward plus the cache state it leaves, on a copy of the same cache that has
//  already taken one step (a copy is a view sized to the prefix, so its first
//  step regrows every layer; that belongs to no width). Widths rotate each round.
//
//  Run: `M1K3_SELFTEST=1 M1K3_SELFTEST_VERIFYCOST=1 M1K3_SELFTEST_MODEL=<the brain's full model id>`.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.6, Prior: none (new
//  file; the cache handling follows MLXBrainProvider+SeedEquivalenceProbe).
//  Context: Kev, 2026-11-11: "a relook at MTP for speedups". The app's weights
//  sit in a closed container, so only the app can time them.
//  Review: Kev + claude-fable-5.2, 2026-11-11 (review fold) — the copy takes one untimed step first, the cache
//  state is forced inside the clock, the widths rotate, and the median is reported beside the best.
//  Open: one prefix length (the persona); a long history is not timed.
//

import Foundation
import M1K3Inference
import MLX
import MLXLMCommon

extension MLXBrainProvider {
    static let verifyCostRounds = 12
    static let verifyCostWidths = [1, 2, 3, 4]

    public func verifyCostProbe() async -> String {
        let container: ModelContainer
        do {
            container = try await ensureLoaded()
        } catch {
            return "verify cost: load failed — \(error)"
        }
        let persona = M1K3Persona.systemPrompt(variant: personaVariant)
        let parameters = generateParameters
        let modelID = modelIdentifier
        do {
            return try await container.perform { context in
                let prefix = try self.systemBlockIDs(context: context, persona: persona, specs: nil)
                let next = context.tokenizer.encode(text: " The tide gauge at the north pier read three metres at noon.")
                guard let widest = Self.verifyCostWidths.max(), next.count > widest else {
                    return "verify cost: the probe text is too short"
                }
                let base = try context.model.newCache(parameters: parameters)
                // Lil (the Qwen3.5 VLM) refuses to continue a warm cache without the state its prefill returns.
                let state = try Self.prefillExactly(
                    prefix, into: base, state: nil, parameters: parameters, model: context.model
                )
                let forward = { (tokens: [Int], cache: [KVCache]) in
                    let text = LMInput.Text(tokens: MLXArray(tokens))
                    let output = context.model(text[text: .newAxis], cache: cache, state: state)
                    eval(output.logits)
                    eval(cache.flatMap { $0.innerState() })
                }
                var samples = [Int: [Double]]()
                // Round 0 is unmeasured: the first use of a shape compiles its kernels.
                for round in 0 ... Self.verifyCostRounds {
                    let widths = Self.verifyCostWidths
                    for index in widths.indices {
                        let width = widths[(index + round) % widths.count]
                        let cache = base.map { $0.copy() }
                        forward([next[0]], cache) // the copy's one-off regrow, outside the clock
                        let took = ContinuousClock().measure { forward(Array(next[1 ... width]), cache) }
                        guard round > 0 else { continue }
                        let ms = Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1000
                        samples[width, default: []].append(ms)
                    }
                }
                return Self.verifyCostReport(model: modelID, prefixTokens: prefix.count + 1, samples: samples)
            }
        } catch {
            return "verify cost: ERROR \(String(describing: error).prefix(160))"
        }
    }

    /// Pure: the report. Each width's best time as a multiple of one token, the speed-up a perfect drafter of
    /// that width could reach (T tokens for the price of one verify of T), and the median beside the best.
    static func verifyCostReport(model: String, prefixTokens: Int, samples: [Int: [Double]]) -> String {
        guard let one = samples[1]?.min(), one > 0 else { return "verify cost: no single-token timing" }
        var lines = ["verify cost [\(model)] on a \(prefixTokens)-token prefix (\(samples[1]?.count ?? 0) rounds):"]
        for width in samples.keys.sorted() {
            guard let times = samples[width]?.sorted(), let best = times.first else { continue }
            let ratio = best / one
            lines.append(String(
                format: "  T=%d: best %.1f ms (median %.1f) = %.2fx one token; a perfect drafter tops out at %.2fx",
                width, best, times[times.count / 2], ratio, Double(width) / ratio
            ))
        }
        return lines.joined(separator: "\n")
    }
}
