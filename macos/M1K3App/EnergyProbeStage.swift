//
//  EnergyProbeStage.swift
//  M1K3App
//
//  #696 Phase 1's verify-by-launch, dev-only: can the SHIPPING app read its own
//  energy counter from inside its sandbox, and how much of one Lil generation
//  does that counter see? Reads `ProcessEnergyCounter` (RUSAGE_INFO_V6
//  `ri_energy_nj`) before and after one plain generation, and prints the CPU
//  joules beside the coefficient estimate the energy ledger would record for
//  the same tokens.
//
//      M1K3_SELFTEST=1 M1K3_SELFTEST_ENERGY=1 M1K3_SELFTEST_OUT=-
//      M1K3_SELFTEST_MODEL=mlx-community/Qwen3.5-4B-MLX-4bit   (so the core generate stage reuses Lil)
//      M1K3_SELFTEST_ENERGY_MODEL=<id>                          (optional; default Lil)
//
//  The counter is CPU-only (docs/ENERGY_MEASUREMENT.md: a Metal burn that kept
//  the GPU busy 1.94–1.99 s of 2 s moved it 0.009–0.045 J, four runs, plain and
//  sandboxed), so expect the CPU joules to be a small share of the estimate; the
//  GPU is the rest, and only powermetrics sees it. Everything one-time happens
//  BEFORE the window opens: the weights load, the persona seed `generate` reuses
//  is built (cold, that is a ~2.4k-token prefill on Lil), and one short
//  throwaway generation absorbs first-use setup. The warm-up's seconds are
//  printed, so the cold cost is visible rather than hidden. The window then
//  holds one warm generation, its own prefill past the seed and its decode:
//  what the ledger prices. Thinking is off and the answer capped at 256 tokens.
//
//  SelfTest never builds AppEnvironment, so no app sink is installed: the stage
//  owns the process-wide metrics reporter for its window and clears it after.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.75 (compiles under the
//  app-shell xcodebuild; never launched yet — the run's eval stage owns the MLX
//  slot). Prior: none (new file; MemBlockProbeStage's shape).
//  Review: Kev + claude-opus-5.5, 2026-10-26 (pre-push review fold) — the window was not the generation's own: a cold
//  persona seed (`generate` builds it on first use) and first-use setup ran inside it, so the CPU joules and the
//  estimate described different work. Now warmed outside the window (`warmPersonaPrefix(tools: [])`, the bare key
//  `generate` asks for, plus one throwaway generation), with the warm-up's seconds printed. The tier comes from the
//  ledger's own resolver. GPU figures quoted as the doc's measured range. Still never launched. Confidence 0.75.
//

import Foundation
import M1K3Inference
import M1K3MLX
import os

enum EnergyProbeStage {
    static var isRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_ENERGY") == "1"
    }

    private static let question = "In three sentences, explain how a heat pump keeps a house warm."

    static func run(emit: @escaping (String) -> Void) async {
        emit("• energy: the RUSAGE_INFO_V6 read inside the app, then one generation…")
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        guard let opening = ProcessEnergyCounter.read() else {
            emit("✗ energy: proc_pid_rusage(RUSAGE_INFO_V6) failed (sandboxed: \(sandboxed), errno \(errno))")
            return
        }
        emit("✓ energy: V6 read inside the app (sandboxed: \(sandboxed)) "
            + "energy_nj=\(opening.energyNJ) billed=\(opening.billedEnergy)")

        guard let modelID = SelfTestEnv.value("M1K3_SELFTEST_ENERGY_MODEL") ?? BrainTier.lil.mlxModelID else {
            emit("✗ energy: no model id")
            return
        }
        let tier = BrainTier(generatingModelID: modelID)
        let captured = OSAllocatedUnfairLock<GenerationMetrics?>(initialState: nil)
        GenerationMetricsReporter.install { metrics in captured.withLock { $0 = metrics } }
        defer { GenerationMetricsReporter.install(nil) }
        do {
            let provider = MLXBrainProvider(modelID: modelID, maxTokens: 256, name: "energy", thinkingEnabled: false)
            emit("• energy: loading \(modelID)…")
            try await provider.prepare(progress: { _ in })

            // Outside the window: the persona seed `generate` reuses, then one short
            // throwaway generation for first-use setup. Its report is discarded.
            let clock = ContinuousClock()
            let warmStart = clock.now
            await provider.warmPersonaPrefix(tools: [])
            _ = try await provider.generate(prompt: "Say OK.")
            emit(String(
                format: "• energy: warm-up outside the window (persona seed + one throwaway generation): %.2f s",
                Self.seconds(clock.now - warmStart)
            ))
            captured.withLock { $0 = nil }

            let before = ProcessEnergyCounter.read()
            let start = clock.now
            let answer = try await provider.generate(prompt: question)
            let elapsed = clock.now - start
            let after = ProcessEnergyCounter.read()
            let seconds = Self.seconds(elapsed)

            guard let metrics = captured.withLock({ $0 }) else {
                emit("✗ energy: the generation reported no GenerationMetrics")
                return
            }
            let prefill = metrics.prefilledTokens ?? metrics.promptTokens
            emit(String(
                format: "energy gen [%@]: %.2f s, context=%d prefilled=%d decode=%d tok @ %.0f tok/s, %d chars",
                modelID, seconds, metrics.promptTokens, prefill, metrics.generationTokens,
                metrics.tokensPerSecond, answer.count
            ))
            guard let before, let after, let cpuJoules = after.joules(since: before) else {
                emit("✗ energy: the window's second read failed")
                return
            }
            let performanceJoules = Double(after.performanceEnergyNJ &- before.performanceEnergyNJ) / 1e9
            emit(String(
                format: "energy cpu (measured, CPU only): %.3f J over the window (%.2f W), P-cores %.3f J, billed Δ %lld",
                cpuJoules, seconds > 0 ? cpuJoules / seconds : 0, performanceJoules,
                Int64(bitPattern: after.billedEnergy &- before.billedEnergy)
            ))
            if let tier, let rate = EnergyCoefficients.rate(for: tier) {
                let estimate = TurnEnergy.estimate(
                    tier: tier, prefillTokens: prefill, decodeTokens: metrics.generationTokens, rate: rate
                )
                let share = estimate.joules > 0 ? 100 * cpuJoules / estimate.joules : 0
                emit(String(
                    format: "energy estimate (%@, %@, rate measured on %@): %.1f J = %d × %.4f + %d × %.4f; "
                        + "the CPU counter saw %.1f %% of it",
                    tier.rawValue, rate.calibrated ? "calibrated" : "uncalibrated", rate.measuredOn, estimate.joules,
                    prefill, rate.joulesPerPrefillToken, metrics.generationTokens, rate.joulesPerDecodeToken, share
                ))
            } else {
                emit("energy estimate: \(tier?.rawValue ?? modelID) is unpriced (no watts measured on this Mac)")
            }
            emit("✓ energy: done — the CPU joules are measured; the estimate is not (docs/ENERGY_MEASUREMENT.md)")
        } catch {
            emit("✗ energy: \(error)")
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
