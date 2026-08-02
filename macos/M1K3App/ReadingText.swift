//
//  ReadingText.swift
//  M1K3App
//
//  Renders a string in the active ReadingMode (default / serif / OpenDyslexic /
//  bionic). One place owns the font + spacing + bionic-emphasis decisions so the
//  chat bubbles and the Settings preview stay identical. Always selectable.
//
//  Signed: Kev + claude-sonnet-4-6, 2026-06-08, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-sonnet-5, 2026-07-22, Confidence 0.85 — this used to
//  hand the WHOLE string to one Text (MessageTextPolish had already flattened
//  markdown away, so a chat bubble showed literal `#` headings and ```-fenced
//  code verbatim). Now it parses real markdown blocks (ChatMarkdownParser) and
//  renders each one properly: headings scale by level, fenced code gets its own
//  highlighted CodeBlockView, lists get bullets/ordinals, quotes get a rule,
//  thematic breaks become a Divider. Inline emphasis/code/links (Foundation's
//  own markdown parser tags them as presentationIntent/inlinePresentationIntent/
//  link) are re-mapped onto SwiftUI font/color attributes against the active
//  ReadingMode's base font, so bold/italic/inline-code/links render for real in
//  every mode except bionic, which still works on the block's plain characters
//  (its whole premise is uniform word-boldening, same as before this change).

import M1K3Chat
import SwiftUI

struct ReadingText: View {
    let text: String
    /// Force a specific mode (Settings previews); otherwise follow the saved choice.
    private let forcedMode: ReadingMode?

    @AppStorage(ReadingMode.storageKey) private var savedModeRaw = ReadingMode.standard.rawValue

    init(_ text: String, mode: ReadingMode? = nil) {
        self.text = text
        forcedMode = mode
    }

    private var mode: ReadingMode {
        forcedMode ?? ReadingMode(rawValue: savedModeRaw) ?? .standard
    }

    private var blocks: [ChatMarkdownBlock] {
        ChatMarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, content):
            proseText(content, font: headingFont(level))
        case let .paragraph(content):
            proseText(content, font: baseFont)
        case let .listItem(ordinal, content):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordinal.map { "\($0)." } ?? "•")
                    .font(baseFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                proseText(content, font: baseFont)
            }
        case let .blockquote(content):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.secondary.opacity(0.4))
                    .frame(width: 3)
                proseText(content, font: baseFont)
                    .foregroundStyle(.secondary)
            }
        case let .codeBlock(language, code):
            CodeBlockView(code: code, language: language)
        case .thematicBreak:
            Divider()
        case let .table(header, rows):
            tableView(header: header, rows: rows)
        }
    }

    /// A markdown table (Kev's catch, live-testing markdown rendering: every
    /// cell has its own leaf identity, so without this the table read as a
    /// flat list of every cell's text, one per line). Plain Grid — no
    /// striping/borders yet, just real rows and columns instead of word salad.
    private func tableView(header: [AttributedString], rows: [[AttributedString]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
            if !header.isEmpty {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        proseText(cell, font: baseFont.weight(.semibold))
                    }
                }
                Divider()
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        proseText(cell, font: baseFont)
                    }
                }
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.06), in: .rect(cornerRadius: 10))
    }

    /// One prose block (heading/paragraph/list-item/quote), styled per the
    /// active ReadingMode. Bionic mode works on the block's plain characters
    /// (markdown markers are already gone — the parser stripped them); every
    /// other mode keeps the block's real inline emphasis/code/link runs.
    private func proseText(_ content: AttributedString, font: Font) -> some View {
        Group {
            if mode == .bionic {
                Text(bionic(String(content.characters), baseFont: font))
            } else {
                Text(styled(content, baseFont: font))
            }
        }
        // Dyslexia mode's roomier spacing applies to every prose block, headings
        // included. (Nothing here touches CodeBlockView — code stays code
        // regardless of ReadingMode.)
        .lineSpacing(mode == .dyslexia ? 6 : 2)
        .tracking(mode == .dyslexia ? 0.5 : 0)
    }

    private var baseFont: Font {
        switch mode {
        case .standard, .bionic: .body
        case .serif: .system(.body, design: .serif)
        case .dyslexia: .dyslexic(15)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        let sizeByLevel: [Int: CGFloat] = [1: 22, 2: 19, 3: 17, 4: 15, 5: 14, 6: 13]
        let size = sizeByLevel[level] ?? 15
        switch mode {
        case .standard, .bionic: return .system(size: size, weight: .bold)
        case .serif: return .system(size: size, weight: .bold, design: .serif)
        case .dyslexia: return .dyslexicBold(size)
        }
    }

    /// Re-maps Foundation's markdown-derived inline intents (bold/italic/code/
    /// strikethrough/link) onto SwiftUI attributes against `baseFont`, so the
    /// active ReadingMode's typeface still governs prose while emphasis, inline
    /// code, and links render distinctly. Inline code always goes monospaced
    /// regardless of `baseFont` — a code span should look like code.
    private func styled(_ content: AttributedString, baseFont: Font) -> AttributedString {
        var result = content
        for run in content.runs {
            var font = baseFont
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { font = font.bold() }
                if inline.contains(.emphasized) { font = font.italic() }
                if inline.contains(.code) { font = .system(.callout, design: .monospaced) }
                if inline.contains(.strikethrough) {
                    result[run.range].strikethroughStyle = .single
                }
            }
            result[run.range].font = font
            if run.link != nil {
                result[run.range].foregroundColor = .accentColor
                result[run.range].underlineStyle = .single
            }
        }
        return result
    }

    /// Build an AttributedString that bolds the leading characters of each word.
    private func bionic(_ source: String, baseFont: Font) -> AttributedString {
        var result = AttributedString()
        for run in BionicTextFormatter.runs(source) {
            if !run.bold.isEmpty {
                var bold = AttributedString(String(run.bold))
                bold.font = baseFont.bold()
                result += bold
            }
            if !run.rest.isEmpty {
                var rest = AttributedString(String(run.rest))
                rest.font = baseFont
                result += rest
            }
        }
        return result
    }
}
