//
//  LocalisationRatchetScanTests.swift
//  M1K3ChatTests
//
//  Localisation Phase 0 (plan 2026-11-18, §3 and §4), two source scans in the style of
//  RetiredPrivacyAbsolutesScanTests:
//
//  1. A ratchet. A `_ title: String` view helper renders its argument verbatim, so the
//     catalog never sees the literal a caller passes; an English plural ternary
//     (`n == 1 ? "item" : "items"`) cannot be translated at all (Phase 0 rewrote the app's
//     ones as `^[…](inflect: true)` keys). Both counts may only go down. A model-facing
//     English plural (a tool result, a prompt line) is fine: mark its line `l10n-ok` with
//     the reason, as the brain must keep reading English.
//  2. A do-not-translate fence. What a MODEL reads stays a plain English String: the
//     persona, the per-turn grounding, the egress disclosure, the leak guard's taught
//     decline, every tool's description and result, the MCP and Local API wire text, and
//     the CLI. Translating one side of those breaks the KV cache, the pinned renders, the
//     leak guard's exact-match compare, or an agent parsing a reply.
//
//  Signed: claude-opus-5-5, 2026-11-19, Confidence 0.75 (line heuristics: a helper or a
//  ternary split across lines slips past, and the fence lists files, so a tool written
//  in a new folder needs its folder added — the `AgentTool` conformance scan catches most).
//  Prior: none (new file).
//  Review: claude-opus-5-5, 2026-11-19 — review fold: the fence takes DownloadErrors.swift (its integrity
//  sentences) and two fenced LINES in DownloadFailureCopy.swift (offline, disk full): `knownMessage` feeds
//  AppStateLine's model line, while the file's other copy is display-only. Confidence 0.75.
//

import Foundation
import Testing

struct LocalisationRatchetScanTests {
    /// Counted on 2026-11-19 after the Phase 0 slices (5: CallsView ×2, ContentView and
    /// ChatScreen's aboutTextPill, MessageBubble's activityRow). Lower it when one goes.
    static let titleHelperBaseline = 5
    /// Counted on 2026-11-19 (19: mostly model-facing tool and grounding text, plus
    /// IngestStatusCopy, WeightImportDisplay, ParkedRecordings, MemoryConstellation and the
    /// Screengrab audit report, whose English needs plural variants before it can move).
    static let pluralTernaryBaseline = 19

    static let shells = ["M1K3App", "M1K3iOSApp", "M1K3visionOS", "M1K3LiveActivityExtension", "Sources"]

    static var titleHelper: Regex<Substring> {
        /\b_\s+(?:title|label|caption|heading|header|subtitle|detail)\s*:\s*String\b/
    }

    static var pluralTernary: Regex<Substring> {
        /(?:[!=]=|>|<=?)\s*1\s*\?\s*(?:"[^"\n]*"|singular)\s*:\s*(?:"[^"\n]*"|plural)/
    }

    static var localisingAPI: Regex<Substring> {
        /String\(localized:|LocalizedStringResource|LocalizedStringKey|\bText\("/
    }

    /// `macos/`, the package root, resolved from this file (Tests/M1K3ChatTests/<file>).
    static var macosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func swiftFiles(under folders: [String]) -> [URL] {
        var files: [URL] = []
        for folder in folders {
            let dir = macosRoot.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Lines that compile: `//` comment lines are skipped (provenance quotes old code).
    static func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.components(separatedBy: "\n").enumerated().compactMap { index, line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? nil : (index + 1, line)
        }
    }

    /// `_ title: String` helpers, counted only in files that import SwiftUI (a view helper;
    /// `TodoGroundingBlock.isSpecific(_ title:)` is data, not UI).
    static func titleHelperHits(_ source: String, file: String) -> [String] {
        guard source.contains("import SwiftUI") else { return [] }
        let helper = titleHelper
        return codeLines(source).compactMap { number, text in
            text.contains("String") && text.contains(helper) ? "\(file):\(number): \(text.trimmingCharacters(in: .whitespaces))" : nil
        }
    }

    static func pluralTernaryHits(_ source: String, file: String) -> [String] {
        let ternary = pluralTernary
        // The cheap `contains` first: the regex over every line of the tree took 24 s.
        return codeLines(source).compactMap { number, text in
            text.contains("1") && text.contains("?") && text.contains(ternary) && !text.contains("l10n-ok")
                ? "\(file):\(number): \(text.trimmingCharacters(in: .whitespaces))" : nil
        }
    }

    static func hits(_ scan: (String, String) -> [String]) throws -> [String] {
        try swiftFiles(under: shells).flatMap { url in
            try scan(String(contentsOf: url, encoding: .utf8), url.path.replacingOccurrences(of: macosRoot.path + "/", with: ""))
        }
    }

    @Test("the scans see the shapes they ratchet, and skip comments and marked lines")
    func scansSeeTheShapes() {
        let view = """
        import SwiftUI
        private func pill(_ title: String) -> some View { Text(title) }
        // private func old(_ label: String) — a review comment quoting it
        let s = n == 1 ? "item" : "items"
        let t = "\\(n) file\\(n == 1 ? "" : "s")"
        let u = "\\(n) \\(n == 1 ? singular : plural)"
        let tool = count == 1 ? "thing" : "things" // l10n-ok: a tool result the model reads
        """
        #expect(Self.titleHelperHits(view, file: "V.swift") == ["V.swift:2: private func pill(_ title: String) -> some View { Text(title) }"])
        #expect(Self.pluralTernaryHits(view, file: "V.swift").map { $0.prefix(9) } == ["V.swift:4", "V.swift:5", "V.swift:6"])
        let data = "import Foundation\nstatic func isSpecific(_ title: String) -> Bool { true }"
        #expect(Self.titleHelperHits(data, file: "D.swift").isEmpty, "only SwiftUI files hold view helpers")
    }

    @Test("no NEW `_ title: String` view helper (the catalog never sees what a caller passes)")
    func titleHelpersOnlyGoDown() throws {
        let hits = try Self.hits(Self.titleHelperHits)
        #expect(
            hits.count <= Self.titleHelperBaseline,
            "take a LocalizedStringKey (or Text) instead; \(hits.count) > \(Self.titleHelperBaseline):\n\(hits.joined(separator: "\n"))"
        )
    }

    @Test("no NEW English plural ternary (use ^[…](inflect: true) or a catalog plural; mark model-facing ones l10n-ok)")
    func pluralTernariesOnlyGoDown() throws {
        let hits = try Self.hits(Self.pluralTernaryHits)
        #expect(
            hits.count <= Self.pluralTernaryBaseline,
            "\(hits.count) > \(Self.pluralTernaryBaseline):\n\(hits.joined(separator: "\n"))"
        )
    }
}

struct DoNotTranslateFenceTests {
    /// Plan §4 by file: the persona and per-turn grounding, the egress clause, the leak
    /// guard (its `taughtDecline` is compared word for word), the tool menu, the lending refusal an agent
    /// reads, the AFM tool palette, and the Local API and CLI wire text.
    static let fencedFiles = [
        "Sources/M1K3Inference/M1K3Persona.swift",
        "Sources/M1K3Inference/M1K3Persona+PrivateCloud.swift",
        "Sources/M1K3Chat/PromptContext.swift",
        "Sources/M1K3Chat/EgressDisclosure.swift",
        "Sources/M1K3Chat/PersonaLeakGuard.swift",
        "Sources/M1K3Chat/ToolDispatch.swift",
        "Sources/M1K3Inference/AFMNativeTool.swift",
        "Sources/M1K3Inference/AFMToolPicker.swift",
        "Sources/M1K3Inference/AFMToolMapping.swift",
        "Sources/M1K3LanguageModel/PrivateCloudLending.swift",
        // The integrity refusals reach AppStateLine's model line via DownloadFailureCopy.knownMessage.
        "Sources/M1K3MLX/DownloadErrors.swift",
    ]
    /// Model-facing lines in a file whose other copy is display-only: `DownloadFailureCopy.knownMessage`
    /// (offline, disk full, integrity) becomes a brain-load failure, which AppStateLine writes into
    /// every turn's grounding and the system_status tool result.
    static let fencedLines = [
        (file: "Sources/M1K3Inference/DownloadFailureCopy.swift", text: "Couldn't reach the download server."),
        (file: "Sources/M1K3Inference/DownloadFailureCopy.swift", text: "Not enough space on this device."),
    ]
    /// Whole folders of model or wire text: the tools, the MCP surfaces, the Local API, the CLI.
    static let fencedFolders = [
        "Sources/M1K3AgentTools", "Sources/M1K3KnowledgeTools", "Sources/M1K3MCPKit",
        "Sources/M1K3LocalAPI", "Sources/M1K3CLICore",
    ]
    /// Files fenced only when present: ReplyLanguage (the reply rule) lands on its own branch.
    static let fencedIfPresent = ["Sources/M1K3Chat/ReplyLanguage.swift", "Sources/M1K3Inference/ReplyLanguage.swift"]

    static func fenced() throws -> [URL] {
        let root = LocalisationRatchetScanTests.macosRoot
        var urls = fencedFiles.map { root.appendingPathComponent($0) }
        urls += LocalisationRatchetScanTests.swiftFiles(under: fencedFolders)
        urls += fencedIfPresent.map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        // Any type that is an AgentTool, wherever it lives: its description and result are model input.
        for url in LocalisationRatchetScanTests.swiftFiles(under: ["Sources"]) {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("AgentTool"), source.contains(/(?:struct|final class|class|actor|extension)\s+\w+\s*:[^{\n]*\bAgentTool\b/) {
                urls.append(url)
            }
        }
        return Array(Set(urls)).sorted { $0.path < $1.path }
    }

    static func localisingLines(_ source: String) -> [Int] {
        let api = LocalisationRatchetScanTests.localisingAPI
        return LocalisationRatchetScanTests.codeLines(source).compactMap { number, text in
            text.contains(api) ? number : nil
        }
    }

    @Test("the fence covers the persona, the grounding, the leak guard and the tools")
    func fenceCoversTheSurfaces() throws {
        let paths = try Self.fenced().map(\.path)
        for suffix in [
            "M1K3Persona.swift", "PromptContext.swift", "EgressDisclosure.swift", "PersonaLeakGuard.swift",
            "M1K3AgentTools/WebSearchTool.swift", "M1K3KnowledgeTools/SearchKnowledgeTool.swift",
            "M1K3MCPKit/MemoryMCPTools.swift", "M1K3Chat/ToolDispatch.swift",
        ] {
            #expect(paths.contains { $0.hasSuffix(suffix) }, "fence lost \(suffix)")
        }
        for path in paths {
            #expect(FileManager.default.fileExists(atPath: path), "fenced file moved: \(path)")
        }
    }

    @Test("a seeded String(localized:) or Text(\"…\") is caught; a comment is not")
    func seededLocalisationIsCaught() {
        let source = """
        // was String(localized: "…") before the fence
        static let decline = String(localized: "I can't share that.")
        let r = LocalizedStringResource("x")
        Text("Hi")
        Text(verbatim: "fine")
        """
        #expect(Self.localisingLines(source) == [2, 3, 4])
    }

    @Test("brain-load failure sentences stay plain English: knownMessage feeds AppStateLine")
    func fencedLinesHold() throws {
        let root = LocalisationRatchetScanTests.macosRoot
        for fenced in Self.fencedLines {
            let source = try String(contentsOf: root.appendingPathComponent(fenced.file), encoding: .utf8)
            let lines = LocalisationRatchetScanTests.codeLines(source).filter { $0.text.contains(fenced.text) }
            #expect(lines.count == 1, "fenced line moved or doubled: \(fenced.file): \(fenced.text)")
            for line in lines where line.text.contains(LocalisationRatchetScanTests.localisingAPI) {
                Issue.record("model-facing text must stay plain English (plan §4): \(fenced.file):\(line.number)")
            }
        }
    }

    @Test("what a model reads stays plain English: no String(localized:) behind the fence")
    func fenceHolds() throws {
        for url in try Self.fenced() {
            let lines = try Self.localisingLines(String(contentsOf: url, encoding: .utf8))
            for line in lines {
                Issue.record("model-facing text must stay a plain English String (plan §4): \(url.path):\(line)")
            }
        }
    }
}
