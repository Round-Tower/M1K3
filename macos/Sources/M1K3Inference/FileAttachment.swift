//
//  FileAttachment.swift
//  M1K3Inference
//
//  A document attached to a single chat turn — its extracted text rides the
//  turn as grounding context, not ingested into the permanent RAG corpus.
//  The difference: an image goes to the model's vision tower; a file goes to
//  the prompt as text the model can read and reason over.
//
//  Signed: Kev + claude-opus-4-6, 2026-09-16, Confidence 0.85,
//  Prior: ImageAttachment (the established pattern)
//  Review: Kev + claude-opus-4-6, 2026-09-17 — added UUID id for stable
//  ForEach identity (two files with the same name must not collide).
//  Review: Kev + claude-opus-5.5, 2026-10-26 — #708: `omittingContextBlocks(from:)`, the inverse the field
//  report needs. The transcript stores a file turn whole (blocks + typed words), so a sent exchange
//  would carry every attached file's text; this keeps the typed words and leaves one marker that
//  names neither the files nor their text. Ambiguity settles toward stripping. Confidence 0.85.
//

import Foundation

public struct FileAttachment: Identifiable, Sendable, Equatable, Hashable, Codable {
    public let id: UUID
    public let filename: String
    public let extractedText: String

    public init(id: UUID = UUID(), filename: String, extractedText: String) {
        self.id = id
        self.filename = filename
        self.extractedText = extractedText
    }

    public var contextBlock: String {
        """
        FILE: \(filename)
        ---
        \(extractedText)
        ---
        """
    }

    /// A user turn as it may leave the Mac (#708, "Send this exchange"). The composers prepend
    /// each attached file's `contextBlock` to the typed words, and the transcript stores that
    /// turn whole, so the stored text holds every file's extracted text. This returns the typed
    /// words behind one marker ("[2 attached files — not included]") that carries neither the
    /// files' text nor their names, since a filename can be as personal as the text.
    ///
    /// Blocks only ever LEAD a turn, so a turn that does not open with a block header comes back
    /// unchanged. A file's own text can hold `---` lines, so the boundary is ambiguous; it is
    /// settled toward stripping: the blocks run to the LAST block close in the turn, a turn that
    /// ends on a close is all blocks, and a block that never closes takes the rest. At worst
    /// some typed words go too (and the count runs high), never file text.
    public static func omittingContextBlocks(from text: String) -> String {
        // NSString's literal, UTF-16 comparisons on purpose: Swift's String compares graphemes,
        // and a file text ending in a bare CR fuses with the block's "\n" into one "\r\n"
        // grapheme, which `hasSuffix("\n---")` would miss — and the last block would ride along.
        let turn = text as NSString
        let firstBreak = turn.range(of: "\n", options: .literal)
        guard turn.hasPrefix(blockHeader), firstBreak.location != NSNotFound,
              turn.range(
                  of: "\n---\n", options: [.literal, .anchored],
                  range: NSRange(location: firstBreak.location, length: turn.length - firstBreak.location)
              ).location != NSNotFound
        else { return text }
        var blocks = text
        var typed = ""
        let close = turn.range(of: blockSeparator, options: [.literal, .backwards])
        if !turn.hasSuffix("\n---"), close.location != NSNotFound {
            blocks = turn.substring(to: close.location)
            typed = turn.substring(from: close.location + close.length)
        }
        let count = (blocks as NSString).components(separatedBy: blockSeparator + blockHeader).count
        let marker = count == 1 ? "[1 attached file — not included]" : "[\(count) attached files — not included]"
        return typed.isEmpty ? marker : marker + "\n\n" + typed
    }

    private static let blockHeader = "FILE: "
    /// A block's close and the blank line after it: what follows is the next block or the typed words.
    private static let blockSeparator = "\n---\n\n"
}
