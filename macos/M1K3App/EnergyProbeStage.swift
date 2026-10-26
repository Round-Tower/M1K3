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
//  The counter is CPU-only (docs/ENERGY_MEASUREMENT.md: a Metal burn moved it
//  0.02 J), so expect the CPU joules to be a small share of the estimate; the
//  GPU is the rest, and only powermetrics sees it. The weights load before the
//  window opens, so the delta is the generation's own. Thinking is off and the
//  answer capped at 256 tokens: one ordinary answer, not a thought to the cap.
//
//  SelfTest never builds AppEnvironment, so no app sink is installed: the stage
//  owns the process-wide metrics reporter for its window and clears it after.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.75 (compiles under the
//  app-shell xcodebuild; never launched yet — the run's eval stage owns the MLX
//  slot). Prior: none (new file; MemBlockProbeStage's shape).
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
        let tier = BrainTier.allCases.first { $0.mlxModelID == modelID }
        let captured = OSAllocatedUnfairLock<GenerationMetrics?>(initialState: nil)
        GenerationMetricsReporter.install { metrics in captured.withLock { $0 = metrics } }
        defer { GenerationMetricsReporter.install(nil) }
        do {
            let provider = MLXBrainProvider(modelID: modelID, maxTokens: 256, name: "energy", thinkingEnabled: false)
            emit("• energy: loading \(modelID)…")
            try await provider.prepare(progress: { _ in })

            let before = ProcessEnergyCounter.read()
            let clock = ContinuousClock()
            let start = clock.now
            let answer = try await provider.generate(prompt: question)
            let elapsed = clock.now - start
            let after = ProcessEnergyCounter.read()
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

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
                    format: "energy estimate (%@, %@): %.1f J = %d × %.4f + %d × %.4f; the CPU counter saw %.1f %% of it",
                    tier.rawValue, rate.calibrated ? "calibrated" : "uncalibrated", estimate.joules,
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
}
