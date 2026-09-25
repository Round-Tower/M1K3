//
//  KokoroDownloadSizeTests.swift
//  M1K3KokoroTests
//
//  The size M1K3 Voice quotes must be the size it downloads. The label said
//  "~184 MB" (the MiB figure) while iOS reports decimal MB — 192 — for the
//  same bytes (iPad field test, 2026-09-25). Pinned to the manifest so a
//  re-pin that changes the bytes fails here until the label moves too.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-25, Confidence 0.9. Prior: none (new file).
//

@testable import M1K3Kokoro
import M1K3Voice
import Testing

struct KokoroDownloadSizeTests {
    /// `voices-v1.0.bin` is a GitHub release asset (immutable once published),
    /// outside the HF pin — its size is recorded here, measured 2026-09-25.
    private static let voicesBytes: Int64 = 28_214_398

    @Test("VoiceTier's quoted MB matches the pinned files + voices, in decimal MB")
    func quotedSizeMatchesPinnedBytes() {
        let pinned = KokoroPinnedWeights.files.values.reduce(Int64(0)) { $0 + $1.size }
        let totalMB = Int((Double(pinned + Self.voicesBytes) / 1_000_000).rounded())
        #expect(VoiceTier.m1k3Voice.approxDownloadMB == totalMB)
    }
}
