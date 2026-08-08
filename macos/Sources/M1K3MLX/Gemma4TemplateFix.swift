//
//  Gemma4TemplateFix.swift
//  M1K3MLX
//
//  Installs Google's canonical gemma-4 chat template (published 2026-07-09:
//  fixed tool-calling loops, turn closures, null-argument handling, thinking
//  content-ordering) over the stale 2026-06-03 template that
//  mlx-community/gemma-4-12B-it-4bit still ships — 7 weeks unpropagated as
//  of 2026-08-08, and the template IS our tool-calling contract (the
//  `.gemma4` dialect drives the native GemmaFunctionParser off it).
//
//  The template is tokenizer metadata, fully independent of the safetensors,
//  so replacing the file is exactly what a re-quantize would have carried.
//  Vendored bytes: fetched from mlx-community/gemma-4-12B-it-OptiQ-4bit at
//  revision c5183df9 (2026-07-20, commit "Sync chat template from Google
//  canonical, published 2026-07-09"), sha256-verified at vendor time and
//  re-verified by the self-consistency test.
//
//  Ordering is load-bearing: apply() runs BEFORE WeightIntegrityScan.enforce
//  at every bridge call site, because the pinned manifest now expects the
//  FIXED template's hash — a fresh snapshot (stale bytes) must be healed
//  before it is judged. Exact-hash-gated both ways: only the known-stale
//  template is ever replaced; anything unrecognised is left for the scan to
//  rule on (never "helpfully" overwritten — that would hide real tampering).
//
//  Signed: Kev + claude-fable-5, 2026-08-08, Confidence 0.85 (decision +
//  filesystem behaviour + manifest self-consistency pinned red-first; the
//  live effect on gemma-4 multi-call tool chains is measured by the eval
//  arm, not assumed). Prior: none (new file).
//

import CryptoKit
import Foundation
import os

public enum Gemma4TemplateFix {
    /// The one repo whose template we replace. The drafter repos keep theirs —
    /// drafting consumes token ids, never the chat template.
    public static let repoID = "mlx-community/gemma-4-12B-it-4bit"

    /// sha256 of the stale 2026-06-03 template mlx-community still serves
    /// (the hash our manifest pinned before this fix existed).
    public static let staleSHA256 =
        "36e3a42e5cf14cd0020e72d92e1fdd9970f59b82170e421f0cbe1bb42bead3f0"

    /// sha256 of the vendored canonical template (Google, 2026-07-09).
    public static let canonicalSHA256 =
        "ae53464bf3be25802b3a5b37def7fd89667067d7577049b3b2d74c4d8de4c6d4"

    public enum Decision: Sendable, Equatable {
        case replace
        case alreadyFixed
        case leaveAlone
    }

    public enum ApplyResult: Sendable, Equatable {
        case replaced
        case alreadyFixed
        case leftAlone
        case notApplicable
    }

    public enum TemplateError: Error {
        case vendoredResourceMissing
        case vendoredResourceCorrupt(expected: String, got: String)
    }

    private static let log = Logger(subsystem: "app.m1k3", category: "weight-integrity")

    /// The vendored canonical template bytes, integrity-checked on every read
    /// (a corrupted resource must fail loudly, never install silently wrong).
    public static func canonicalTemplate() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "gemma4-chat-template-canonical", withExtension: "jinja"
        ) else { throw TemplateError.vendoredResourceMissing }
        let data = try Data(contentsOf: url)
        let sha = sha256Hex(data)
        guard sha == canonicalSHA256 else {
            throw TemplateError.vendoredResourceCorrupt(expected: canonicalSHA256, got: sha)
        }
        return data
    }

    /// Pure: what to do with an on-disk template of this hash.
    public static func decision(
        existingSHA256: String, staleSHA256: String = Gemma4TemplateFix.staleSHA256
    ) -> Decision {
        if existingSHA256 == staleSHA256 { return .replace }
        if existingSHA256 == canonicalSHA256 { return .alreadyFixed }
        return .leaveAlone
    }

    /// Replace a known-stale `chat_template.jinja` under `directory` with the
    /// vendored canonical bytes. Missing file (mid-download) and unknown
    /// hashes are left untouched. `treatingAsStale` widens the stale hash for
    /// tests only.
    @discardableResult
    public static func apply(
        directory: URL,
        repoID: String,
        treatingAsStale staleSHA256: String = Gemma4TemplateFix.staleSHA256
    ) throws -> ApplyResult {
        guard repoID == Self.repoID else { return .notApplicable }
        let templateURL = directory.appendingPathComponent("chat_template.jinja")
        guard let existing = try? Data(contentsOf: templateURL) else { return .leftAlone }
        switch decision(existingSHA256: sha256Hex(existing), staleSHA256: staleSHA256) {
        case .alreadyFixed:
            return .alreadyFixed
        case .leaveAlone:
            return .leftAlone
        case .replace:
            let canonical = try canonicalTemplate()
            // Atomic: a torn write must never leave a half-template a later
            // launch would neither recognise as stale nor pass the scan with.
            try canonical.write(to: templateURL, options: .atomic)
            log.notice(
                "gemma-4 chat template healed to Google's 2026-07-09 canonical (\(repoID, privacy: .public))"
            )
            return .replaced
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
