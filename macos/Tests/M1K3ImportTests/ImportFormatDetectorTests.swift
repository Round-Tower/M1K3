//
//  ImportFormatDetectorTests.swift
//  M1K3ImportTests
//
//  #711: one drop target, three shapes. A JSON array whose conversations carry `mapping` is
//  ChatGPT's, `chat_messages` is Claude's, a folder of frontmatter markdown is another M1K3's OKF
//  export; anything else is refused rather than guessed at.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85.
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — pins the sample window (stray non-objects
//  skipped, `sampleSize` objects decide), typed keys (`"mapping": null` is no export), the exporter-only OKF rule (a
//  notes folder with `type:` frontmatter is refused), and the non-array root through `parse(data:)`. Confidence 0.85.

import Foundation
@testable import M1K3Import
import M1K3Memory
import Testing

struct ImportFormatDetectorTests {
    private let chatgpt = ChatGPTFixture.linear(
        id: "c1", title: "Bees", createTime: 1, messages: [("user", "I keep bees"), ("assistant", "Nice.")]
    )
    private let claude = ClaudeFixture.conversation(
        uuid: "u1", name: "Fiddle", messages: [ClaudeFixture.message(sender: "human", text: "I play the fiddle")]
    )

    @Test("mapping → ChatGPT, chat_messages → Claude, anything else → nil")
    func threeShapes() throws {
        #expect(try ImportFormatDetector.detect(data: ChatGPTFixture.data([chatgpt])) == .chatgpt)
        #expect(try ImportFormatDetector.detect(data: ClaudeFixture.data([claude])) == .claude)
        #expect(ImportFormatDetector.detect(data: Data("[]".utf8)) == nil)
        #expect(ImportFormatDetector.detect(data: Data(#"{"mapping": {}}"#.utf8)) == nil)
        #expect(ImportFormatDetector.detect(data: Data(#"[{"messages": []}]"#.utf8)) == nil)
        #expect(ImportFormatDetector.detect(data: Data("not json".utf8)) == nil)
    }

    @Test("a folder with a fact OKFExport wrote is M1K3's; plain markdown or another tool's notes are not")
    func folders() {
        let fact = OKFExport.File(
            name: "bees-1a2b3c4d.md",
            content: "---\ntype: profile\ntimestamp: 2026-10-26T12:00:00Z\nsource: \"distilled\"\n---\n\n"
                + "Kev keeps bees\n"
        )
        let readme = OKFExport.File(name: "README.md", content: "# M1K3 memory export\n")
        #expect(ImportFormatDetector.detect(files: [readme, fact]) == .m1k3)
        #expect(ImportFormatDetector.detect(files: [readme]) == nil)
        #expect(ImportFormatDetector.detect(files: [OKFExport.File(name: "a.md", content: "# Notes\n")]) == nil)
        let vaultNote = OKFExport.File(
            name: "post.md", content: "---\ntype: post\ntitle: \"Hello\"\n---\n\nMy blog post\n"
        )
        #expect(ImportFormatDetector.detect(files: [vaultNote]) == nil)
        let real = OKFExport.files(
            memories: [Memory(kind: .note, text: "Kev keeps bees", source: "distilled")], edges: [], exportedAt: Date()
        )
        #expect(ImportFormatDetector.detect(files: real) == .m1k3)
    }

    @Test("parse(data:) reads the file once and hands it to the right parser")
    func parseDispatches() throws {
        #expect(try ImportFormatDetector.parse(data: ChatGPTFixture.data([chatgpt])).provider == .chatgpt)
        let claudeBundle = try ImportFormatDetector.parse(data: ClaudeFixture.data([claude]))
        #expect(claudeBundle.provider == .claude)
        #expect(claudeBundle.conversations.first?.messages.first?.text == "I play the fiddle")
        #expect(throws: ImportParseError.unrecognisedFormat) {
            try ImportFormatDetector.parse(data: Data(#"[{"messages": []}]"#.utf8))
        }
        #expect(throws: ImportParseError.notJSON) { try ImportFormatDetector.parse(data: Data("x".utf8)) }
    }

    // MARK: - Review fold

    @Test("stray non-objects are skipped, not counted; the first sampleSize objects decide")
    func sampleWindow() throws {
        let junk: [Any] = [1, "x", NSNull(), [1, 2]]
        let claudeFirst: [Any] = junk + [claude]
        let manyJunk: [Any] = Array(repeating: "x", count: 10) + [chatgpt]
        let unrelated: [Any] = Array(repeating: ["messages": [] as [Any]], count: ImportFormatDetector.sampleSize)
            + [chatgpt]

        #expect(try ImportFormatDetector.detect(data: JSONSerialization.data(withJSONObject: claudeFirst)) == .claude)
        #expect(try ImportFormatDetector.detect(data: JSONSerialization.data(withJSONObject: manyJunk)) == .chatgpt)
        #expect(try ImportFormatDetector.detect(data: JSONSerialization.data(withJSONObject: unrelated)) == nil)
    }

    @Test("a key only counts with its type: a null mapping or chat_messages is no export")
    func typedKeys() {
        #expect(ImportFormatDetector.detect(data: Data(#"[{"mapping": null}]"#.utf8)) == nil)
        #expect(ImportFormatDetector.detect(data: Data(#"[{"chat_messages": null}]"#.utf8)) == nil)
        #expect(ImportFormatDetector.detect(data: Data(#"[{"chat_messages": []}]"#.utf8)) == .claude)
    }

    @Test("a root that is not an array is unrecognised through parse(data:)")
    func nonArrayRootIsUnrecognised() {
        #expect(throws: ImportParseError.unrecognisedFormat) {
            try ImportFormatDetector.parse(data: Data(#"{"mapping": {}}"#.utf8))
        }
    }
}
