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
//  Review: Kev + claude-opus-5-5, 2026-10-06 — one heal per repo (`Heal`): E4B joins 12B.
//  mlx-community/gemma-4-e4b-it-4bit still serves the pre-07-15 template (`2f1b4d75…`);
//  Google's current E4B template (`0a2c8073…`, google/gemma-4-E4B-it @ ee0ef602) is a
//  DIFFERENT file from 12B's, so each repo heals to its own vendored bytes and a stale
//  hash is only ever judged against its own repo's pair. 12B's API is unchanged.
//  Review: same day (#497 review fold) — the 12B `decision(existingSHA256:)` overload lost its
//  stale-hash parameter: a custom stale hash would have been judged against 12B's canonical.
//  E4B is unpinned, so the hash gate is its only template check — pin it before it becomes a tier.
//  Confidence 0.85.
//  Review: Kev + claude-fable-5.1, 2026-10-09 — E2B joins (mobile audition). Its stale hash is
//  E4B's `2f1b4d75…` and google/gemma-4-E2B-it's template hashes to E4B's `0a2c8073…`, so the
//  Heal reuses E4B's vendored resource. Confidence 0.85 (hashes fetched read-only over https).
//

import CryptoKit
import Foundation
import os

public enum Gemma4TemplateFix {
    /// One repo's heal: the stale hash it may serve and the vendored canonical
    /// bytes that replace it. Exact repo ids only — another conversion (OptiQ
    /// already ships the new template) is never touched.
    public struct Heal: Sendable, Equatable {
        public let repoID: String
        public let staleSHA256: String
        public let canonicalSHA256: String
        let resourceName: String
    }

    /// 12B (the shipped Big), E4B (the 1.1 Lil candidate) and E2B (the mobile candidate). The drafter repos
    /// keep theirs — drafting consumes token ids, never the chat template.
    public static let heals: [Heal] = [
        Heal(
            repoID: repoID, staleSHA256: staleSHA256, canonicalSHA256: canonicalSHA256,
            resourceName: "gemma4-chat-template-canonical"
        ),
        Heal(
            repoID: "mlx-community/gemma-4-e4b-it-4bit",
            staleSHA256: "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082",
            canonicalSHA256: "0a2c8073c878ab1da004bee933a998606537bbb62016310352c7285c3f01c5b5",
            resourceName: "gemma4-e4b-chat-template-canonical"
        ),
        // E2B (mobile / Mini-vision / audio audition): same stale hash, and Google's E2B template
        // is byte-identical to E4B's (both sha256 0a2c8073…, fetched 2026-10-09), so it shares
        // E4B's vendored resource rather than carrying a second copy.
        Heal(
            repoID: "mlx-community/gemma-4-e2b-it-4bit",
            staleSHA256: "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082",
            canonicalSHA256: "0a2c8073c878ab1da004bee933a998606537bbb62016310352c7285c3f01c5b5",
            resourceName: "gemma4-e4b-chat-template-canonical"
        ),
    ]

    /// The heal for `repoID`, or nil when the repo is not one we heal.
    public static func heal(for repoID: String) -> Heal? {
        heals.first { $0.repoID == repoID }
    }

    /// The 12B repo — the original (and still the shipped) heal.
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
        try canonicalTemplate(for: heals[0])
    }

    /// `heal`'s vendored bytes, integrity-checked on every read.
    public static func canonicalTemplate(for heal: Heal) throws -> Data {
        guard let url = Bundle.module.url(forResource: heal.resourceName, withExtension: "jinja") else {
            throw TemplateError.vendoredResourceMissing
        }
        let data = try Data(contentsOf: url)
        let sha = sha256Hex(data)
        guard sha == heal.canonicalSHA256 else {
            throw TemplateError.vendoredResourceCorrupt(expected: heal.canonicalSHA256, got: sha)
        }
        return data
    }

    /// Pure: what to do with an on-disk 12B template of this hash. No stale-hash
    /// parameter: a caller passing another repo's stale hash would be judged
    /// against 12B's canonical (#497 review) — other repos go through `heal:`.
    public static func decision(existingSHA256: String) -> Decision {
        decision(existingSHA256: existingSHA256, staleSHA256: staleSHA256, canonicalSHA256: canonicalSHA256)
    }

    /// Pure, for one repo's heal: its own stale hash replaces, its own canonical stands.
    public static func decision(existingSHA256: String, heal: Heal) -> Decision {
        decision(existingSHA256: existingSHA256, staleSHA256: heal.staleSHA256, canonicalSHA256: heal.canonicalSHA256)
    }

    private static func decision(existingSHA256: String, staleSHA256: String, canonicalSHA256: String) -> Decision {
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
        treatingAsStale staleOverride: String? = nil
    ) throws -> ApplyResult {
        guard let heal = heal(for: repoID) else { return .notApplicable }
        let templateURL = directory.appendingPathComponent("chat_template.jinja")
        guard let existing = try? Data(contentsOf: templateURL) else { return .leftAlone }
        let stale = staleOverride ?? heal.staleSHA256
        switch decision(existingSHA256: sha256Hex(existing), staleSHA256: stale, canonicalSHA256: heal.canonicalSHA256) {
        case .alreadyFixed:
            return .alreadyFixed
        case .leaveAlone:
            return .leftAlone
        case .replace:
            let canonical = try canonicalTemplate(for: heal)
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
