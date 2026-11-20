//
//  MLXRuntimeSupport.swift
//  M1K3Inference
//
//  Can this device run MLX at all? Two ways it can't, and both end the process
//  rather than throw, so the shell must never try:
//
//  • the Simulator — no Metal GPU; merely setting MLX's cache limit aborts.
//  • Apple GPU family 5 (A12 / A12X / A12Z) — the compiler cannot build MLX's
//    kernels (MTLCompilerService: "unable to legalize … bfloat"; the fp16
//    re-quant got past gather and died on rms, so it is the family, not the
//    dtype). mlx-swift's default error handler then traps. Seen with LFM2 as
//    Mini (#236) and with M1K3 Voice on an iPad 8th gen (2026-09-25).
//
//  Family 6 (A13) is the floor: proven-bad below it, untested AT it. Pure — the
//  shell probes Metal (`supportsFamily(.apple6)`) and passes the answer in.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-25, Confidence 0.85 (A12 proven twice
//  on device; the A13 floor is inferred, not measured). Prior: none (new file).
//  Review: claude-opus-5-5, 2026-11-19 — localisation Phase 0: `voiceNote` and `brainFallbackNote` resolve from
//  M1K3Inference's catalog (`bundle: .module`); rg shows only the iOS shell's Settings rows read them (AppCore.brainNote
//  renders in SettingsScreen alone). The tier name stays an argument. English unchanged.
//

import Foundation

public enum MLXRuntimeSupport: Equatable, Sendable {
    case available
    case simulator
    case gpuTooOld

    public static func resolve(isSimulator: Bool, gpuSupportsApple6: Bool) -> Self {
        if isSimulator { return .simulator }
        return gpuSupportsApple6 ? .available : .gpuTooOld
    }

    public var isAvailable: Bool {
        self == .available
    }

    /// Why M1K3 Voice (Kokoro on MLX) isn't offered — nil when it is. Display-only (the iOS
    /// voice section), so it resolves from M1K3Inference's catalog.
    public var voiceNote: String? {
        switch self {
        case .available: nil
        case .simulator:
            String(
                localized: "M1K3 Voice runs on a real device.",
                bundle: .module,
                comment: "Settings note in the Simulator. M1K3 Voice is a product name: never translated."
            )
        case .gpuTooOld:
            String(
                localized: "M1K3 Voice needs a newer chip than this device has. Built-in works here.",
                bundle: .module,
                comment: "Settings note on an older chip. M1K3 Voice is a product name: never translated. Built-in names the other voice option: match its translation."
            )
        }
    }

    /// The note when an MLX brain pick falls back to Mini — nil when it wouldn't. Display-only
    /// (Settings' brain section), so it resolves from M1K3Inference's catalog.
    public func brainFallbackNote(tierName: String) -> String? {
        switch self {
        case .available: nil
        case .simulator:
            String(
                localized: "\(tierName) runs on a real device — the Simulator has no GPU for MLX. Staying on Mini.",
                bundle: .module,
                comment: "Settings note in the Simulator. The argument is a brain name (Lil, Big). Mini is a brain name: never translated."
            )
        case .gpuTooOld:
            String(
                localized: "\(tierName) needs a newer chip than this device has. Staying on Mini.",
                bundle: .module,
                comment: "Settings note on an older chip. The argument is a brain name (Lil, Big). Mini is a brain name: never translated."
            )
        }
    }
}
