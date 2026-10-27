//
//  AnswerBlockSegmenter.swift
//  M1K3AnswerBlocks
//
//  Splits an answer into what ReadingText renders (#717): markdown runs, typed
//  blocks, and pending blocks still streaming. Stream-safe by construction:
//
//  • A closed typed fence whose body parses is a `.block`.
//  • A closed typed fence whose body does NOT parse stays inside the markdown,
//    byte for byte, so ChatMarkdownParser renders it as today's code card. No
//    error UI: the model's words are all still there.
//  • An open typed fence, while the turn is still streaming, is `.pending` to the
//    end of the text, so the skeleton shows and the half-written JSON never does.
//    Once the turn has ended (finished, stopped, failed, cut off at the token
//    cap) a fence that never closed is malformed: raw markdown, not a skeleton
//    forever. Only the caller knows which, so it says (`streaming:`).
//  • Ordinary fences (``` or ~~~) are tracked and never split; a typed opener
//    inside one is code (a model showing the format, not using it).
//
//  Why its own scan rather than ChatMarkdownParser: Foundation's markdown parser
//  turns an UNCLOSED fence into a code block to the end and exposes no "closed"
//  flag, and M1K3Voice (which may not import M1K3Chat) needs the same regions.
//  The fence rules are MessageTextPolish's line-based ones, earned by its pinned
//  tests: `\.isNewline` (CRLF is ONE grapheme), any indentation, a close is a
//  line-leading run at least as long as the opener's with only whitespace after,
//  and a backtick opener's info string may not contain backticks (CommonMark),
//  which keeps a same-line ```span``` prose. Tilde fences are tracked here too,
//  since Foundation's parser honours them.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure; pinned case
//  by case and by a seeded fuzz suite). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (self-review fold) — `streaming:`; an open fence was a
//  skeleton forever once a turn ended mid-fence. Defaults to false, the safe side: a caller that
//  forgets it shows today's code card, never a stuck skeleton. Confidence 0.85.
//

import Foundation

/// One piece of an answer, in order.
public enum AnswerBlockSegment: Equatable, Sendable {
    /// Ordinary markdown: a verbatim slice of the answer.
    case markdown(String)
    /// A closed typed fence that parsed.
    case block(AnswerBlock)
    /// A typed fence still open while the turn streams.
    case pending(AnswerBlockKind)
}

public enum AnswerBlockSegmenter {
    /// The answer as segments. Whitespace-only markdown between blocks is
    /// dropped; empty text has no segments. `streaming`: the turn is still
    /// generating, so an open typed fence is a skeleton rather than raw markdown.
    public static func segments(in text: String, streaming: Bool = false) -> [AnswerBlockSegment] {
        var segments: [AnswerBlockSegment] = []
        func appendMarkdown(_ slice: Substring) {
            guard slice.contains(where: { !$0.isWhitespace }) else { return }
            segments.append(.markdown(String(slice)))
        }
        var cursor = text.startIndex
        for region in typedRegions(in: text) {
            if let block = region.block {
                appendMarkdown(text[cursor ..< region.range.lowerBound])
                segments.append(.block(block))
                cursor = region.range.upperBound
            } else if !region.isClosed, streaming {
                appendMarkdown(text[cursor ..< region.range.lowerBound])
                segments.append(.pending(region.kind))
                cursor = text.endIndex
            }
            // A region that didn't parse (or never closed, once the turn is
            // over) stays in the markdown run.
        }
        appendMarkdown(text[cursor...])
        return segments
    }

    /// One typed fence the scan found.
    struct TypedRegion {
        let kind: AnswerBlockKind
        /// From the opener line's start to the closing line's end (its newline
        /// excluded), or to the end of the text when the fence is still open.
        let range: Range<String.Index>
        /// The parsed body; nil when it didn't parse or the fence is open.
        let block: AnswerBlock?
        let isClosed: Bool
    }

    private enum OpenFence {
        case none
        case ordinary(marker: Character, run: Int)
        case typed(kind: AnswerBlockKind, run: Int, start: String.Index, bodyStart: String.Index)
    }

    /// Every typed fence in the text, in order, closed or not, parsed or not.
    /// Shared by the renderer's segments and the speech lane's replacement.
    static func typedRegions(in text: String) -> [TypedRegion] {
        // Nearly every answer has no typed fence: skip the scan.
        guard text.range(of: "m1k3-", options: .caseInsensitive) != nil else { return [] }
        var regions: [TypedRegion] = []
        var open = OpenFence.none
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(where: \.isNewline)
            let contentEnd = newline ?? text.endIndex
            let nextLine = newline.map { text.index(after: $0) } ?? text.endIndex
            let unindented = text[lineStart ..< contentEnd].drop { $0 == " " || $0 == "\t" }
            let marker = unindented.first
            let run = marker == "`" || marker == "~" ? unindented.prefix { $0 == marker }.count : 0
            let rest = unindented.dropFirst(run)
            let closes = { (openMarker: Character, openRun: Int) in
                marker == openMarker && run >= openRun && rest.allSatisfy(\.isWhitespace)
            }
            switch open {
            case .none:
                guard run >= 3, let marker else { break }
                if marker == "`", rest.contains("`") { break } // a same-line span is prose
                let info = rest.trimmingCharacters(in: .whitespaces).lowercased()
                if marker == "`", let kind = AnswerBlockKind(rawValue: info) {
                    open = .typed(kind: kind, run: run, start: lineStart, bodyStart: nextLine)
                } else {
                    open = .ordinary(marker: marker, run: run)
                }
            case let .ordinary(openMarker, openRun):
                if closes(openMarker, openRun) { open = .none }
            case let .typed(kind, openRun, start, bodyStart):
                if closes("`", openRun) {
                    let body = String(text[bodyStart ..< lineStart])
                    regions.append(TypedRegion(
                        kind: kind,
                        range: start ..< contentEnd,
                        block: AnswerBlock.parse(kind: kind, body: body),
                        isClosed: true
                    ))
                    open = .none
                }
            }
            lineStart = nextLine
        }
        if case let .typed(kind, _, start, _) = open {
            regions.append(TypedRegion(kind: kind, range: start ..< text.endIndex, block: nil, isClosed: false))
        }
        return regions
    }
}
