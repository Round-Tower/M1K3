//
//  KokoroPinnedWeights.swift
//  M1K3Kokoro
//
//  Closes issue #70: the two Kokoro files fetched directly from HuggingFace
//  (`config.json`, `kokoro-v1_0.safetensors` — staged locally as
//  `model.safetensors`) were being pulled from an unpinned `main` branch with
//  no byte verification at all, the exact pattern M1K3MLX's WeightIntegrity /
//  PinnedWeights removed everywhere else for the two chat brains + the
//  retrieval embedder (ADR 0002).
//
//  ⚠️ DELIBERATELY NOT a dependency on M1K3MLX. That target would give us
//  `WeightIntegrity`/`WeightIntegrityScan`/`PinnedWeights` for free, but
//  M1K3Kokoro is a leaf target that does its own HTTP by design (see
//  `KokoroSpeechProvider.swift`'s header), and pulling in M1K3MLX — a much
//  heavier target (MLXLLM, the Gemma provider, the whole brain-download
//  stack) — just to reach two constants would be a real layering cost for a
//  handful of bytes. This is issue #70's own "Option 2": pin + verify at the
//  raw-fetch site, accepting a small, deliberate duplication of shape (a
//  revision + a per-file size+sha256 manifest) rather than the cross-target
//  coupling.
//
//  `voices-v1.0.bin` is OUT OF SCOPE for this pin — it comes from a GitHub
//  release (`thewh1teagle/kokoro-onnx`), not HuggingFace, a different host
//  and a different threat surface issue #70 didn't ask this fix to cover.
//
//  TRUST MODEL — mirrors `macos/tools/weights/pin_weights.py`'s own model for
//  PinnedWeights.swift. The digests below are the LOCAL, already-downloaded,
//  already-in-production-use snapshot's own bytes (staged 2026-07-19) AND
//  independently agree with HuggingFace's published values for BOTH files:
//  `config.json`'s sha256 matches the git blob sha1 HuggingFace's API reports
//  for it (`14a726edd3718279eac426630879ff743955b16a`), and
//  `kokoro-v1_0.safetensors`'s sha256 matches the LFS `sha256` HuggingFace's
//  API publishes for it byte-for-byte. Two parties confirming the same
//  bytes — the same trust model PinnedWeights.swift documents.
//
//  Signed: Kev + claude-sonnet-5, 2026-09-01, Confidence 0.85 (both digests
//  independently cross-checked against HuggingFace's own published values for
//  the exact commit pinned below, not just computed from the local file;
//  `matches` is pure and test-pinned. Honest caveat: verifying the download
//  reaching `KokoroSpeechProvider.prepare` end-to-end is verify-by-launch,
//  like the rest of this target — the digest math itself needs no network
//  and no Metal). Prior: Unknown
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

    /// Full 40-char commit SHA for `mlx-community/Kokoro-82M-bf16` — never
    /// `main`. Re-pin with the same care as any other weight promotion:
    /// changing this means shipping different bytes.
    static let revision = "a71e4d38b236d968966a2002c4c895dbd12b1c3c"

    /// Keyed by the LOCAL staged filename — `prepare(progress:)` renames the
    /// upstream `kokoro-v1_0.safetensors` to `model.safetensors` on download,
    /// so verification never has to know the upstream name.
    static let files: [String: PinnedFile] = [
        "config.json": .init(
            size: 2351,
            sha256: "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f"
        ),
        "model.safetensors": .init(
            size: 327_115_152,
            sha256: "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"
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
