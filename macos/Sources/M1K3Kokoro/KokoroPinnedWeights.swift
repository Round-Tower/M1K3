//
//  KokoroPinnedWeights.swift
//  M1K3Kokoro
//
//  Pinned revision + per-file size+sha256 manifest for the Kokoro TTS weights
//  fetched from HuggingFace. Duplicates M1K3MLX's WeightIntegrity shape
//  deliberately — M1K3Kokoro is a leaf target that does its own HTTP (#70).
//
//  `voices-v1.0.bin` is OUT OF SCOPE — it comes from a GitHub release
//  (`thewh1teagle/kokoro-onnx`), not HuggingFace.
//
//  2026-09-19: weights moved from `mlx-community/Kokoro-82M-bf16` (which
//  stored all 548 tensors as F32 despite the name — 312 MB) to
//  `round-tower/Kokoro-82M-bf16` (actual bfloat16 — 156 MB). config.json
//  bytes are identical; model.safetensors is the F32→bf16 conversion with
//  the original digests cross-checked before conversion.
//
//  Signed: Kev + claude-sonnet-5, 2026-09-01, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-4-6, 2026-09-19 — F32→bf16 weight conversion:
//  new repo (round-tower/Kokoro-82M-bf16), model.safetensors 312→156 MB,
//  config.json unchanged. Original F32 digests verified against the old pin
//  before conversion. Confidence 0.85.
//

import CryptoKit
import Foundation

/// The pinned commit + per-file manifest for the two HuggingFace-sourced
/// Kokoro files. See this file's header for why it duplicates (rather than
/// imports) M1K3MLX's `WeightIntegrity` shape.
enum KokoroPinnedWeights {
    struct PinnedFile: Equatable {
        let size: Int64
        let sha256: String
    }

    /// Full 40-char commit SHA for `round-tower/Kokoro-82M-bf16` — never
    /// `main`. Re-pin with the same care as any other weight promotion:
    /// changing this means shipping different bytes.
    static let revision = "c4d633d996a0d3c69dd6333f8515286b9d92f9b0"

    static let files: [String: PinnedFile] = [
        "config.json": .init(
            size: 2351,
            sha256: "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f"
        ),
        "model.safetensors": .init(
            size: 163_588_165,
            sha256: "235a936cbf762c07625543eec9f76af08bb401151534e692307ecc3ce80c5818"
        ),
    ]

    /// Pure verdict: do `size`/`sha256` match what is pinned for `name`? A
    /// filename this manifest doesn't recognise (`voices-v1.0.bin`, or
    /// anything else) is not this pin's concern and passes through — mirrors
    /// `WeightIntegrity.Verdict.unpinned`'s permissiveness for anything the
    /// manifest doesn't name.
    static func matches(size: Int64, sha256: String, file name: String) -> Bool {
        guard let pinned = files[name] else { return true }
        return size == pinned.size && sha256 == pinned.sha256
    }

    /// Streaming sha256 of a file on disk — mirrors `WeightIntegrityScan`'s
    /// own streaming hash (never materialise a multi-hundred-MB file), kept
    /// as a small local copy rather than a cross-target import per this
    /// file's header. Returns nil on any read failure (unreadable, not
    /// "wrong" — the caller treats that as "could not verify, discard and
    /// re-fetch" the same way a mismatch is treated).
    static func sha256Digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
