//
//  DocumentRendererTests.swift
//  M1K3KnowledgeTests
//
//  A long section is stored as sliding windows that overlap by about 200
//  characters (DocumentChunker.overlapChars), which is right for retrieval and
//  wrong for reading: get_document printed every overlap twice. Found live
//  2026-11-13 through the Claude Code plugin, on a two-chunk memory.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85. Prior: none
//  (new file; the paging pins stay in KnowledgeMCPToolsTests).
//

import Foundation
@testable import M1K3Knowledge
import Testing

struct DocumentRendererTests {
    private func chunks(_ texts: [String], heading: String? = nil) -> [KnowledgeChunk] {
        let item = UUID()
        return texts.enumerated().map { index, text in
            KnowledgeChunk(itemID: item, ordinal: index, heading: heading, content: text)
        }
    }

    /// A body long enough for the real chunker to window it: distinct numbered
    /// words, so any repeat in the render is the overlap and nothing else.
    private static let longBody = (1 ... 900).map { "word\($0)" }.joined(separator: " ")

    @Test("the chunker's overlapping windows render as the original text, each word once")
    func overlapIsStitched() {
        let windows = DocumentChunker.splitIntoWindows(Self.longBody)
        #expect(windows.count > 2) // the fixture really is windowed
        let out = DocumentRenderer.render(
            title: "Long", kind: .memory, chunks: chunks(windows), maxChars: 1_000_000
        )
        let body = out.replacingOccurrences(of: "# Long  [memory]\n\n", with: "")
        #expect(body == Self.longBody)
    }

    @Test("a windowed section prints its heading once, not once per window")
    func headingIsNotRepeated() {
        let windows = DocumentChunker.splitIntoWindows(Self.longBody)
        let out = DocumentRenderer.render(
            title: "Long", kind: .document, chunks: chunks(windows, heading: "3.2 Seals"), maxChars: 1_000_000
        )
        #expect(out.components(separatedBy: "## 3.2 Seals").count == 2)
        #expect(out.components(separatedBy: "word450 ").count == 2)
    }

    @Test("chunks that share no text are left exactly as they were, a blank line apart")
    func distinctChunksUntouched() {
        let out = DocumentRenderer.render(
            title: "Two", kind: .note,
            chunks: chunks(["The hydraulic seal failed under load.", "Operators must wear gloves near the press."])
        )
        #expect(out == "# Two  [note]\n\nThe hydraulic seal failed under load.\n\nOperators must wear gloves near the press.")
    }

    @Test("a shared run shorter than a window overlap is a coincidence and both copies stay")
    func shortRepeatIsKept() {
        // Two long chunks of one section that share 60 characters at the join: more than
        // a few words, far less than the chunker's ~200. Nothing may be cut.
        let shared = String(String(repeating: "shared words here ", count: 4).prefix(60))
        #expect(shared.count == 60)
        let first = String(repeating: "alpha ", count: 40) + shared
        let second = shared + String(repeating: " omega", count: 40)
        let out = DocumentRenderer.render(title: "Two", kind: .note, chunks: chunks([first, second]))
        #expect(out.contains(first + "\n\n" + second))
    }

    @Test("the floor is half the chunker's overlap: one under stays, at the floor it stitches")
    func overlapFloorBoundary() {
        let floor = DocumentRenderer.minimumOverlap
        #expect(floor == DocumentChunker.overlapChars / 2)
        func run(_ count: Int) -> String {
            String((0 ..< count).map { Character(UnicodeScalar(UInt8(97 + $0 % 26))) })
        }
        let under = run(floor - 1)
        #expect(DocumentRenderer.remainderAfterOverlap(previous: "start " + under, next: under + " end") == nil)
        let exact = run(floor)
        #expect(DocumentRenderer.remainderAfterOverlap(previous: "start " + exact, next: exact + " end") == " end")
    }

    @Test("a match that stops mid-word is periodic text, not a window, and is left alone")
    func periodicTextIsNotOverlap() {
        // A long rule of dashes at the end of one chunk and the start of the next.
        let rule = String(repeating: "-", count: 150)
        let out = DocumentRenderer.render(
            title: "Rules", kind: .note, chunks: chunks(["Above the line " + rule, rule + rule + " below the line"])
        )
        #expect(out.components(separatedBy: "-").count - 1 == 450)
    }

    @Test("sections with different headings are never stitched, even when their text repeats")
    func differentHeadingsNeverStitch() {
        let repeated = "This exact sentence closes one section and opens the next one."
        let item = UUID()
        let out = DocumentRenderer.render(
            title: "Doc", kind: .document,
            chunks: [
                KnowledgeChunk(itemID: item, ordinal: 0, heading: "A", content: "Intro. \(repeated)"),
                KnowledgeChunk(itemID: item, ordinal: 1, heading: "B", content: "\(repeated) Outro."),
            ]
        )
        #expect(out.components(separatedBy: repeated).count == 3)
        #expect(out.contains("## B\n"))
    }

    @Test("paging offsets count the stitched body, so two pages rebuild the text with nothing doubled")
    func pagingRunsOverStitchedBody() {
        let windows = DocumentChunker.splitIntoWindows(Self.longBody)
        let all = chunks(windows)
        let half = Self.longBody.count / 2
        let first = DocumentRenderer.render(title: "Long", kind: .memory, chunks: all, maxChars: half)
        #expect(first.contains("offset:\(half)"))
        #expect(first.contains("\(Self.longBody.count - half) more characters"))
        let second = DocumentRenderer.render(
            title: "Long", kind: .memory, chunks: all, maxChars: 1_000_000, offset: half
        )
        #expect(second.hasSuffix("[— end of document —]"))
        let tail = String(Self.longBody.dropFirst(half))
        #expect(second.contains(tail))
    }
}
