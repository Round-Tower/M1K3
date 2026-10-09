//
//  SeedProbeStage.swift
//  M1K3App
//
//  THE SEEDED-PREFILL PROBE (M1K3_SELFTEST_SEEDPROBE=1, or a model id).
//
//  Runs `SeededPrefillProbe` on both load paths (MLXVLM, then the MLXLLM control) for one
//  model from the app's own store: does appending a turn to a seeded cache give the same next
//  token as a full prefill, with `state: nil` and with the prefix's state carried? The gate
//  before Qwen3.5 can take Lil with an exact seed (docs/GEMMA_1_1_PLAN.md, 2026-10-07 shootout).
//  The model is never downloaded: an absent one is reported.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.8 (app-target glue in
//  MemBlockProbeStage's shape; verify-by-launch like every SelfTest arm). Prior: none (new file).
//

import Foundation
import M1K3MLX

enum SeedProbeStage {
    /// "1" probes the default (Qwen3.5-4B); any other value is a model id.
    static var modelID: String? {
        guard let value = SelfTestEnv.value("M1K3_SELFTEST_SEEDPROBE"), !value.isEmpty else { return nil }
        return value == "1" ? SeededPrefillProbe.defaultModelID : value
    }

    static var isRequested: Bool {
        modelID != nil
    }

    static func run(emit: @escaping (String) -> Void) async {
        guard let modelID else { return }
        for path in SeededPrefillProbe.LoadPath.allCases {
            emit("• seed probe: \(modelID) via \(path.rawValue)…")
            do {
                for line in try await SeededPrefillProbe.run(modelID: modelID, path: path) {
                    emit(line)
                }
            } catch {
                emit("✗ seed probe \(path.rawValue): \(error)")
            }
        }
    }
}
