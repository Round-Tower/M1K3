//
//  Gemma4TemplateFixTests.swift
//  M1K3MLXTests
//
//  Pins the vendored-template override: Google fixed gemma-4's chat template
//  on 2026-07-09 (tool-calling loops, turn closures, null args) but
//  mlx-community/gemma-4-12B-it-4bit still ships the stale 2026-06-03 one —
//  so M1K3 vendors the canonical template and installs it over exactly the
//  stale bytes, before the integrity scan (whose manifest pins the FIXED
//  hash) ever looks. Exact-hash-gated: an unknown template is never touched.
//
//  Signed: Kev + claude-fable-5, 2026-08-08, Confidence 0.9 (pure decision +
//  temp-dir filesystem behaviour + vendored-bytes/manifest self-consistency,
//  all red-first). Prior: none (new file).
//

import CryptoKit
import Foundation
@testable import M1K3MLX
import Testing

struct Gemma4TemplateFixTests {
    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("the vendored template loads and matches its published provenance hash")
    func vendoredBytesSelfConsistent() throws {
        let data = try Gemma4TemplateFix.canonicalTemplate()
        #expect(sha256(data) == Gemma4TemplateFix.canonicalSHA256)
        let text = String(decoding: data, as: UTF8.self)
        // The canonical template's own header names the fix; the null-argument
        // branch is one of the concrete July changes.
        #expect(text.contains("Fixed tool-calling loops"))
        #expect(text.contains("argument is none"))
    }

    @Test("the pinned manifest expects the FIXED template, not the stale one")
    func manifestPinsFixedTemplate() throws {
        let entry = try #require(
            PinnedWeights.all["mlx-community/gemma-4-12B-it-4bit"]?
                .files["chat_template.jinja"]
        )
        let data = try Gemma4TemplateFix.canonicalTemplate()
        #expect(entry.sha256 == Gemma4TemplateFix.canonicalSHA256)
        #expect(entry.size == data.count)
    }

    @Test("decision: stale bytes replace, canonical bytes stand, unknown bytes are never touched")
    func decisions() throws {
        let canonical = try Gemma4TemplateFix.canonicalTemplate()
        #expect(Gemma4TemplateFix.decision(existingSHA256: Gemma4TemplateFix.staleSHA256) == .replace)
        #expect(Gemma4TemplateFix.decision(existingSHA256: sha256(canonical)) == .alreadyFixed)
        #expect(Gemma4TemplateFix.decision(existingSHA256: "deadbeef") == .leaveAlone)
    }

    @Test("apply replaces exactly the stale template on disk, idempotently")
    func applyReplacesStale() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma4-template-fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A stand-in for the stale template: apply is HASH-gated, so the test
        // installs bytes whose hash the fix treats as stale via the seam.
        let templateURL = dir.appendingPathComponent("chat_template.jinja")
        let staleBytes = Data("stale template".utf8)
        try staleBytes.write(to: templateURL)

        let first = try Gemma4TemplateFix.apply(
            directory: dir,
            repoID: "mlx-community/gemma-4-12B-it-4bit",
            treatingAsStale: sha256(staleBytes)
        )
        #expect(first == .replaced)
        let onDisk = try Data(contentsOf: templateURL)
        #expect(sha256(onDisk) == Gemma4TemplateFix.canonicalSHA256)

        let second = try Gemma4TemplateFix.apply(
            directory: dir,
            repoID: "mlx-community/gemma-4-12B-it-4bit",
            treatingAsStale: sha256(staleBytes)
        )
        #expect(second == .alreadyFixed)
    }

    @Test("apply leaves unknown templates and other repos alone")
    func applyLeavesOthersAlone() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma4-template-fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let templateURL = dir.appendingPathComponent("chat_template.jinja")
        let unknown = Data("some other template".utf8)
        try unknown.write(to: templateURL)

        // Unknown hash in the right repo: untouched.
        let verdict = try Gemma4TemplateFix.apply(
            directory: dir, repoID: "mlx-community/gemma-4-12B-it-4bit"
        )
        #expect(verdict == .leftAlone)
        #expect(try Data(contentsOf: templateURL) == unknown)

        // Wrong repo: not even considered.
        let otherRepo = try Gemma4TemplateFix.apply(
            directory: dir, repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        )
        #expect(otherRepo == .notApplicable)

        // Missing file (mid-download): untouched, no throw.
        try FileManager.default.removeItem(at: templateURL)
        let missing = try Gemma4TemplateFix.apply(
            directory: dir, repoID: "mlx-community/gemma-4-12B-it-4bit"
        )
        #expect(missing == .leftAlone)
    }
}
