//
//  VoiceTierRestore.swift
//  M1K3Voice
//
//  The launch-time decision for the M1K3 Voice (Kokoro) tier, made testable and
//  shared by every shell: reload the neural voice only when the user chose it
//  before AND its weights are already on disk. Chosen-but-missing must never kick
//  a silent ~354 MB re-download on launch; staged-but-unchosen must never load a
//  voice the user didn't pick. The same shape as M1K3Calls' CallTranscriptionRestore
//  (and the Mac's inline rule in AppEnvironment.init), lifted here so the iOS shell
//  and the Mac share one rule instead of two copies.
//
//  Also the first-run default: Built-in. M1K3 Voice is a download, and the tap on
//  it IS the consent — nothing downloads until asked.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-03, Confidence 0.9 (pure policy,
//  four-way pinned in VoiceTierRestoreTests; patterned on CallTranscriptionRestore).
//  Prior: none (new file).
//

public enum VoiceTierRestore {
    /// Restore M1K3 Voice on launch only if it was the chosen tier AND the model is
    /// already staged. Both must hold — see the file header for why each half
    /// alone is wrong.
    public static func shouldRestore(selected: VoiceTier, modelStaged: Bool) -> Bool {
        selected == .m1k3Voice && modelStaged
    }

    /// Decode the persisted tier; anything missing or unknown is Built-in — the
    /// zero-download default a fresh install (or a stale value) must land on.
    public static func restoredTier(persisted raw: String?) -> VoiceTier {
        raw.flatMap(VoiceTier.init(rawValue:)) ?? .builtin
    }
}
