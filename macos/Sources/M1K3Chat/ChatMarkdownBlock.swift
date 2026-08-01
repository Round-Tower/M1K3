//
//  ChatMarkdownBlock.swift
//  M1K3Chat
//
//  Splits a model's raw markdown reply into block-level pieces — headings,
//  paragraphs, list items, block quotes, fenced code, thematic breaks — so a
//  chat bubble can render each one properly instead of showing literal `#`
//  markers and ```-fenced text verbatim (MessageTextPolish used to flatten
//  markdown away for exactly that reason; now the bubble renders it for
//  real, so the markup has to survive into here — see MessageTextPolish's
//  updated doc comment).
//
//  Built on Foundation's own markdown parser (AttributedString(markdown:))
//  rather than a hand-rolled block splitter: it already gets the hard cases
//  right — an unclosed fence at end-of-stream, fences nested/indented under
//  a bullet, CRLF, a same-line ```span``` vs a real fence — for free, and it
//  never throws: `.returnPartiallyParsedIfPossible` degrades a malformed or
//  mid-stream string to a single literal paragraph instead of failing. Runs
//  are grouped into blocks by their presentationIntent's innermost identity
//  (the leaf paragraph/header/codeBlock/listItem id — verified empirically:
//  every run belonging to one block shares it, including multiple inline
//  runs within one paragraph or list item).
//
//  Signed: Kev + claude-sonnet-5, 2026-07-22, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-sonnet-5, 2026-07-22 — tables were missing entirely:
//  every cell has its OWN leaf identity (unlike a paragraph's runs, which all
//  share one), so the innermost-identity grouping this file is built on
//  turned each cell into its own flat paragraph — a table read as a vertical
//  word-salad in the bubble (Kev's catch, live-testing markdown rendering).
//  Tables need the OPPOSITE grouping (by the outer `.table` identity, shared
//  by every cell in the whole table), so they're accumulated on their own
//  side path in `parse`, never routed through `makeBlock`.

import Foundation

public enum ChatMarkdownBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    /// `ordinal == nil` is a bullet item; otherwise the item's 1-based number.
    case listItem(ordinal: Int?, text: AttributedString)
    case blockquote(AttributedString)
    /// `language` is the fence's info string, lowercased; empty → nil.
    case codeBlock(language: String?, code: String)
    case thematicBreak
    /// `header` is empty when the table had no header row (rare, but the
    /// parser degrades gracefully rather than assuming one always exists).
    case table(header: [AttributedString], rows: [[AttributedString]])
}

public enum ChatMarkdownParser {
    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    /// Parse `text` into ordered blocks. Empty/whitespace-only input yields `[]`.
    public static func parse(_ text: String) -> [ChatMarkdownBlock] {
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            // The parser is documented to degrade rather than throw under
            // .returnPartiallyParsedIfPossible; this is a belt-and-braces
            // fallback so a render path can never crash on model output.
            return [.paragraph(AttributedString(text))]
        }

        var blocks: [ChatMarkdownBlock] = []
        var currentIdentity: Int?
        var currentComponents: [PresentationIntent.IntentType] = []
        var currentText = AttributedString()
        var hasCurrent = false

        var tableIdentity: Int?
        var tableCells: [TableCellCapture] = []

        func flush() {
            guard hasCurrent else { return }
            blocks.append(makeBlock(components: currentComponents, text: currentText))
            currentText = AttributedString()
            hasCurrent = false
        }

        func flushTable() {
            guard tableIdentity != nil else { return }
            blocks.append(assembleTable(tableCells))
            tableCells = []
            tableIdentity = nil
        }

        for run in attributed.runs {
            let components = run.presentationIntent?.components ?? []
            let tableComponent = components.first { if case .table = $0.kind { true } else { false } }

            if let tableComponent {
                if tableIdentity != tableComponent.identity {
                    flush() // a paragraph/heading run in flight never belongs to this table
                    flushTable() // a DIFFERENT table was mid-flight (shouldn't happen, safe anyway)
                    tableIdentity = tableComponent.identity
                }
                var isHeader = false
                var rowIndex = 0
                var columnIndex: Int?
                for component in components {
                    switch component.kind {
                    case .tableHeaderRow: isHeader = true
                    case let .tableRow(index): rowIndex = index
                    case let .tableCell(index): columnIndex = index
                    default: break
                    }
                }
                guard let columnIndex else { continue } // malformed cell — drop rather than guess
                // A styled cell (**bold** / `code` inside it) arrives as several
                // runs sharing one (isHeader, row, column) key — accumulate into
                // the open capture, mirroring what flush()'s currentText does
                // for non-table runs, or each styled run becomes a phantom cell.
                if let last = tableCells.indices.last,
                   tableCells[last].isHeader == isHeader,
                   tableCells[last].rowIndex == rowIndex,
                   tableCells[last].columnIndex == columnIndex
                {
                    tableCells[last].text += attributed[run.range]
                } else {
                    tableCells.append(TableCellCapture(
                        isHeader: isHeader, rowIndex: rowIndex, columnIndex: columnIndex,
                        text: AttributedString(attributed[run.range])
                    ))
                }
                continue
            }
            flushTable() // this run isn't part of a table — close out any table in flight

            let identity = components.first?.identity
            if hasCurrent, identity != currentIdentity {
                flush()
            }
            currentIdentity = identity
            currentComponents = components
            currentText += attributed[run.range]
            hasCurrent = true
        }
        flush()
        flushTable()
        return blocks
    }

    private struct TableCellCapture {
        let isHeader: Bool
        /// Meaningless when `isHeader` — CommonMark doesn't index the header row.
        let rowIndex: Int
        let columnIndex: Int
        /// var: a styled cell accumulates across runs sharing this cell's key.
        var text: AttributedString
    }

    /// Reassembles a table's flattened cell captures into header + ordered
    /// rows. Sorted defensively (by row then column) rather than trusting
    /// emission order — cheap, and the whole point of this file is not
    /// trusting streamed/partial markdown to arrive in a tidy shape.
    private static func assembleTable(_ cells: [TableCellCapture]) -> ChatMarkdownBlock {
        let header = cells.filter(\.isHeader)
            .sorted { $0.columnIndex < $1.columnIndex }
            .map(\.text)
        let bodyByRow = Dictionary(grouping: cells.filter { !$0.isHeader }, by: \.rowIndex)
        let rows = bodyByRow.keys.sorted().map { key in
            bodyByRow[key]!.sorted { $0.columnIndex < $1.columnIndex }.map(\.text)
        }
        return .table(header: header, rows: rows)
    }

    private static func makeBlock(
        components: [PresentationIntent.IntentType], text: AttributedString
    ) -> ChatMarkdownBlock {
        // Code blocks and thematic breaks are unambiguous regardless of what
        // else wraps them (e.g. a fence nested under a bullet also carries
        // listItem/unorderedList components) — checked first so nesting
        // never misclassifies a code block as a list item.
        for component in components {
            if case let .codeBlock(languageHint) = component.kind {
                let code = String(text.characters)
                // .isNewline, not == "\n": a CRLF ending is ONE grapheme that
                // hasSuffix("\n") never matches (the fencedCodeRanges lesson).
                let trimmed = code.last?.isNewline == true ? String(code.dropLast()) : code
                let language = languageHint?.trimmingCharacters(in: .whitespaces).lowercased()
                return .codeBlock(language: (language?.isEmpty ?? true) ? nil : language, code: trimmed)
            }
            if case .thematicBreak = component.kind {
                return .thematicBreak
            }
        }
        for component in components {
            if case let .header(level) = component.kind {
                return .heading(level: level, text: text)
            }
        }

        let isOrdered = components.contains { if case .orderedList = $0.kind { true } else { false } }
        var ordinal: Int?
        var isListItem = false
        for component in components {
            if case let .listItem(number) = component.kind {
                isListItem = true
                if isOrdered { ordinal = number }
            }
        }
        if isListItem {
            return .listItem(ordinal: ordinal, text: text)
        }

        let isBlockquote = components.contains { if case .blockQuote = $0.kind { true } else { false } }
        if isBlockquote {
            return .blockquote(text)
        }

        return .paragraph(text)
    }
}
