//
//  FileAttachmentTests.swift
//  M1K3InferenceTests
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.85 — only the omittingContextBlocks tests (#708:
//  a field report never carries an attached file's text or name). Prior: Unknown (the earlier tests).
//

import Foundation
@testable import M1K3Inference
import Testing

struct FileAttachmentTests {
    @Test("contextBlock includes the filename and extracted text")
    func contextBlockShape() {
        let file = FileAttachment(filename: "notes.pdf", extractedText: "The quick brown fox.")
        let block = file.contextBlock
        #expect(block.contains("FILE: notes.pdf"))
        #expect(block.contains("The quick brown fox."))
        #expect(block.contains("---"))
    }

    @Test("empty text produces a valid block with just the filename")
    func emptyText() {
        let file = FileAttachment(filename: "blank.txt", extractedText: "")
        #expect(file.contextBlock.contains("FILE: blank.txt"))
    }

    @Test("FileAttachment is Codable round-trip")
    func codableRoundTrip() throws {
        let original = FileAttachment(filename: "doc.pdf", extractedText: "Hello world")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileAttachment.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - omittingContextBlocks (#708: what a sent exchange may carry of a file turn)

    /// The user turn exactly as the composers build it: each block, a blank line, the typed words
    /// (ContentView.send / ChatScreen), then trimmed by ChatSession.send.
    private static func turn(_ files: [FileAttachment], typed: String) -> String {
        let fileContext = files.map(\.contextBlock).joined(separator: "\n\n")
        return (fileContext + "\n\n" + typed).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("a file turn keeps the typed words; the file's text and its name become one marker")
    func omitsOneFileBlock() {
        let file = FileAttachment(
            filename: "divorce-settlement.pdf", extractedText: "Clause 4: the house goes to Áine."
        )
        let out = FileAttachment.omittingContextBlocks(from: Self.turn([file], typed: "What does clause 4 mean?"))
        #expect(out == "[1 attached file — not included]\n\nWhat does clause 4 mean?")
        #expect(!out.contains("Clause 4: the house"))
        #expect(!out.contains("divorce-settlement"), "a filename can be as personal as the text")
    }

    @Test("several files, and file text full of rule lines, still leave nothing of any file")
    func omitsSeveralBlocksWhoseTextHasRules() {
        let files = [
            FileAttachment(filename: "a.md", extractedText: "intro\n---\n\nFILE: decoy\n---\nsecret one\n---"),
            FileAttachment(filename: "b.txt", extractedText: "secret two"),
        ]
        let out = FileAttachment.omittingContextBlocks(from: Self.turn(files, typed: "Compare them"))
        #expect(out.hasSuffix("\n\nCompare them"))
        #expect(out.hasPrefix("["))
        for leaked in ["intro", "secret one", "secret two", "a.md", "b.txt"] {
            #expect(!out.contains(leaked), "file content rode along: \(leaked)")
        }
    }

    @Test("files sent with no typed words leave only the marker")
    func filesWithNoTypedWords() {
        let files = [
            FileAttachment(filename: "a.txt", extractedText: "first secret"),
            FileAttachment(filename: "b.txt", extractedText: "second secret"),
        ]
        let out = FileAttachment.omittingContextBlocks(from: Self.turn(files, typed: ""))
        #expect(out == "[2 attached files — not included]")
    }

    @Test("a file text ending in a bare CR still never leaks — the boundary is read byte for byte, not by grapheme")
    func bareCarriageReturnDoesNotHideTheClose() {
        let files = [
            FileAttachment(filename: "a.txt", extractedText: "secret one"),
            FileAttachment(filename: "b.txt", extractedText: "secret two\r"),
        ]
        let out = FileAttachment.omittingContextBlocks(from: Self.turn(files, typed: ""))
        #expect(out == "[2 attached files — not included]")
        let crName = FileAttachment(filename: "c\r", extractedText: "secret three")
        let named = FileAttachment.omittingContextBlocks(from: Self.turn([crName], typed: "why?"))
        #expect(named == "[1 attached file — not included]\n\nwhy?")
    }

    @Test("an empty file's block is omitted too")
    func emptyFileBlock() {
        let file = FileAttachment(filename: "blank.txt", extractedText: "")
        let out = FileAttachment.omittingContextBlocks(from: Self.turn([file], typed: "hello"))
        #expect(out == "[1 attached file — not included]\n\nhello")
    }

    @Test("a turn with no file block comes back unchanged, even one that starts with the word FILE")
    func plainTurnIsUnchanged() {
        for typed in ["What is a context block?", "FILE: notes.txt won't open, why?", "a\n---\n\nb", ""] {
            #expect(FileAttachment.omittingContextBlocks(from: typed) == typed)
        }
    }

    @Test("a block that never closes fails closed: nothing after its header survives")
    func unclosedBlockFailsClosed() {
        let out = FileAttachment.omittingContextBlocks(from: "FILE: cut.txt\n---\nhalf a secret")
        #expect(out == "[1 attached file — not included]")
    }
}
