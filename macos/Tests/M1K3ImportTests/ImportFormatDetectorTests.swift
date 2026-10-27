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

    @Test("a folder with an OKF fact is M1K3's; a folder of plain markdown is not")
    func folders() {
        let fact = OKFExport.File(name: "bees-1a2b3c4d.md", content: "---\ntype: profile\n---\n\nKev keeps bees\n")
        let readme = OKFExport.File(name: "README.md", content: "# M1K3 memory export\n")
        #expect(ImportFormatDetector.detect(files: [readme, fact]) == .m1k3)
        #expect(ImportFormatDetector.detect(files: [readme]) == nil)
        #expect(ImportFormatDetector.detect(files: [OKFExport.File(name: "a.md", content: "# Notes\n")]) == nil)
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
}
