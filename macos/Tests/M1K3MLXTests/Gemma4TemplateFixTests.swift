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

    // E4B (2026-10-06): mlx-community/gemma-4-e4b-it-4bit still serves the pre-07-15 template.

    @Test("E4B's vendored template loads and matches Google's published hash")
    func e4bVendoredTemplateMatches() throws {
        let heal = try #require(Gemma4TemplateFix.heal(for: "mlx-community/gemma-4-e4b-it-4bit"))
        #expect(heal.canonicalSHA256 == "0a2c8073c878ab1da004bee933a998606537bbb62016310352c7285c3f01c5b5")
        #expect(heal.staleSHA256 == "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082")
        #expect(try sha256(Gemma4TemplateFix.canonicalTemplate(for: heal)) == heal.canonicalSHA256)
    }

    @Test("each repo heals to its OWN template — 12B bytes never land in E4B, nor E4B's in 12B")
    func healsNeverCross() throws {
        let twelve = try #require(Gemma4TemplateFix.heal(for: "mlx-community/gemma-4-12B-it-4bit"))
        let e4b = try #require(Gemma4TemplateFix.heal(for: "mlx-community/gemma-4-e4b-it-4bit"))
        #expect(twelve.canonicalSHA256 != e4b.canonicalSHA256)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemma4-template-fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let templateURL = dir.appendingPathComponent("chat_template.jinja")
        let staleBytes = Data("stale e4b template".utf8)
        try staleBytes.write(to: templateURL)

        let verdict = try Gemma4TemplateFix.apply(
            directory: dir, repoID: "mlx-community/gemma-4-e4b-it-4bit", treatingAsStale: sha256(staleBytes)
        )
        #expect(verdict == .replaced)
        #expect(try sha256(Data(contentsOf: templateURL)) == e4b.canonicalSHA256)

        // 12B's stale hash in the E4B repo is not E4B's stale hash: left alone.
        #expect(Gemma4TemplateFix.decision(existingSHA256: twelve.staleSHA256, heal: e4b) == .leaveAlone)
    }

    // E2B (2026-10-09): mlx-community/gemma-4-e2b-it-4bit serves the same stale `2f1b4d75…` and
    // google/gemma-4-E2B-it publishes byte-identical bytes to E4B's (`0a2c8073…`), so the heal
    // reuses E4B's vendored resource — no second copy of the same file.

    @Test("E2B heals to Google's published E2B template (byte-identical to E4B's, one resource)")
    func e2bHealUsesSharedVendoredTemplate() throws {
        let e2b = try #require(Gemma4TemplateFix.heal(for: "mlx-community/gemma-4-e2b-it-4bit"))
        let e4b = try #require(Gemma4TemplateFix.heal(for: "mlx-community/gemma-4-e4b-it-4bit"))
        #expect(e2b.canonicalSHA256 == "0a2c8073c878ab1da004bee933a998606537bbb62016310352c7285c3f01c5b5")
        #expect(e2b.staleSHA256 == "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082")
        #expect(try sha256(Gemma4TemplateFix.canonicalTemplate(for: e2b)) == e2b.canonicalSHA256)
        #expect(try Gemma4TemplateFix.canonicalTemplate(for: e2b) == Gemma4TemplateFix.canonicalTemplate(for: e4b))
        let twelve = try #require(Gemma4TemplateFix.heal(for: "mlx-community/gemma-4-12B-it-4bit"))
        #expect(Gemma4TemplateFix.decision(existingSHA256: twelve.staleSHA256, heal: e2b) == .leaveAlone)
        #expect(Gemma4TemplateFix.decision(existingSHA256: e2b.staleSHA256, heal: e2b) == .replace)
    }

    @Test("only the exact repos heal — the OptiQ conversion already ships the new template")
    func onlyExactRepos() {
        #expect(Gemma4TemplateFix.heal(for: "mlx-community/gemma-4-e4b-it-OptiQ-4bit") == nil)
        #expect(Gemma4TemplateFix.heal(for: "mlx-community/gemma-4-e4b-it-8bit") == nil)
        #expect(Gemma4TemplateFix.heal(for: "mlx-community/gemma-4-e2b-it-8bit") == nil)
        #expect(Gemma4TemplateFix.heal(for: "google/gemma-4-E2B-it") == nil)
    }
}
