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
//  This is the measurement only: no drafter, nothing shipped. Each timing is the
//  best of `rounds` on a fresh deep copy of the same cache, T = 1…4 interleaved.
//
//  Run: `M1K3_SELFTEST=1 M1K3_SELFTEST_VERIFYCOST=1 M1K3_SELFTEST_MODEL=<the brain's full model id>`.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.6, Prior: none (new
//  file; the cache handling follows MLXBrainProvider+SeedEquivalenceProbe).
//  Context: Kev, 2026-11-11: "a relook at MTP for speedups". The app's weights
//  sit in a closed container, so only the app can time them.
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
        let model = modelIdentifier
        do {
            return try await container.perform { context in
                let prefix = try self.systemBlockIDs(context: context, persona: persona, specs: nil)
                let next = context.tokenizer.encode(text: " The tide gauge at the north pier read three metres at noon.")
                guard let widest = Self.verifyCostWidths.max(), next.count >= widest else {
                    return "verify cost: the probe text is too short"
                }
                let base = try context.model.newCache(parameters: parameters)
                // Lil (the Qwen3.5 VLM) refuses to continue a warm cache without the state its prefill returns.
                let state = try Self.prefillExactly(
                    prefix, into: base, state: nil, parameters: parameters, model: context.model
                )
                var best = [Int: Double]()
                // One unmeasured pass per width first: the first use of a shape compiles its kernels.
                for round in 0 ... Self.verifyCostRounds {
                    for width in Self.verifyCostWidths {
                        let cache = base.map { $0.copy() }
                        eval(cache.flatMap { $0.innerState() })
                        let text = LMInput.Text(tokens: MLXArray(Array(next.prefix(width))))
                        let clock = ContinuousClock()
                        let took = clock.measure {
                            let output = context.model(text[text: .newAxis], cache: cache, state: state)
                            eval(output.logits)
                        }
                        guard round > 0 else { continue }
                        let ms = Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1000
                        best[width] = min(best[width] ?? .infinity, ms)
                    }
                }
                return Self.verifyCostReport(model: model, prefixTokens: prefix.count, bestMilliseconds: best)
            }
        } catch {
            return "verify cost: ERROR \(String(describing: error).prefix(160))"
        }
    }

    /// Pure: the report, with each width as a multiple of one token and the speed-up a perfect drafter
    /// of that width could reach (T tokens for the price of one verify of T).
    static func verifyCostReport(model: String, prefixTokens: Int, bestMilliseconds: [Int: Double]) -> String {
        guard let one = bestMilliseconds[1], one > 0 else { return "verify cost: no single-token timing" }
        var lines = ["verify cost [\(model)] on a \(prefixTokens)-token prefix (best of \(verifyCostRounds)):"]
        for width in bestMilliseconds.keys.sorted() {
            guard let ms = bestMilliseconds[width] else { continue }
            let ratio = ms / one
            let ceiling = Double(width) / ratio
            lines.append(String(
                format: "  T=%d: %.1f ms = %.2fx one token; a perfect drafter tops out at %.2fx", width, ms, ratio, ceiling
            ))
        }
        return lines.joined(separator: "\n")
    }
}
