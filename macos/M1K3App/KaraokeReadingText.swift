//
//  KaraokeReadingText.swift
//  M1K3
//
//  The follow-the-spoken-word reading view: renders the utterance with the
//  current word highlighted, spoken text solid, upcoming text dimmed (the
//  Focus-reader pattern — reading support, not decoration). Respects the
//  active ReadingMode, so OpenDyslexic/bionic compose with the highlight —
//  that combination is the point of the feature.
//
//  Paragraph-split rendering: one Text per paragraph (`.id`-ed for
//  auto-scroll); only the paragraph containing the current word re-renders at
//  word cadence — the rest are all-spoken or all-upcoming. Classification is
//  the tested KaraokeTextFormatter; this view only paints.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.75 (paint layer over
//  tested classification; visual tuning verify-at-⌘R). Prior: Unknown.
//

import M1K3Chat
import M1K3Voice
import SwiftUI

struct KaraokeReadingText: View {
    /// The EXACT spoken string (timeline.text when a timeline exists).
    let text: String
    /// Word ranges from the timeline; nil → whitespace-tokenized fallback
    /// (the plain Built-in tier pushes live ranges with no timeline).
    let timeline: SpokenWordTimeline?
    /// UTF-16 range of the word currently being heard.
    let currentWordRange: Range<Int>?

    /// Compact hugs its content — no ScrollView, no claimed height. For the
    /// voice bubbles, where the sentence-streamed line is short and the
    /// surrounding glass should wrap it tightly (Kev: "the view is too
    /// large"). Long content still belongs to the scrolling default.
    var compact = false

    @AppStorage(ReadingMode.storageKey) private var savedModeRaw = ReadingMode.standard.rawValue

    private var mode: ReadingMode {
        ReadingMode(rawValue: savedModeRaw) ?? .standard
    }

    private var wordRanges: [Range<Int>] {
        timeline.map { $0.words.map(\.textRange) } ?? KaraokeTextFormatter.wordRanges(of: text)
    }

    private var currentIndex: Int? {
        currentWordRange.flatMap { KaraokeTextFormatter.index(containing: $0, in: wordRanges) }
    }

    var body: some View {
        let words = wordRanges
        let current = currentIndex
        let paragraphs = ParagraphSplitter.split(text)
        if compact {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(paragraphs.indices, id: \.self) { index in
                    paragraphText(paragraphs[index], allWords: words, globalCurrent: current)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            scrolling(words: words, current: current, paragraphs: paragraphs)
        }
    }

    private func scrolling(
        words: [Range<Int>], current: Int?, paragraphs: [ParagraphSplitter.Paragraph]
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(paragraphs.indices, id: \.self) { index in
                        paragraphText(paragraphs[index], allWords: words, globalCurrent: current)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
            .onChange(of: current) {
                guard let current, current < words.count,
                      let active = paragraphs.firstIndex(where: { $0.range.contains(words[current].lowerBound) })
                else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(active, anchor: .center)
                }
            }
        }
    }

    /// One paragraph, classified locally: words are filtered + rebased into the
    /// paragraph, and the current index is rebased too (count ⇒ all spoken,
    /// nil ⇒ all upcoming for paragraphs we haven't reached).
    private func paragraphText(
        _ paragraph: ParagraphSplitter.Paragraph,
        allWords: [Range<Int>],
        globalCurrent: Int?
    ) -> some View {
        let local = allWords.enumerated().filter { paragraph.range.contains($0.element.lowerBound) }
        let base = paragraph.range.lowerBound
        let localRanges = local.map { ($0.element.lowerBound - base) ..< ($0.element.upperBound - base) }
        let localCurrent: Int?
        if let globalCurrent {
            if let position = local.firstIndex(where: { $0.offset == globalCurrent }) {
                localCurrent = position
            } else if let first = local.first, globalCurrent > first.offset {
                localCurrent = local.count // past this paragraph: everything spoken
            } else {
                localCurrent = nil // not reached yet: everything upcoming
            }
        } else {
            localCurrent = nil
        }
        return Text(attributed(paragraph.text, wordRanges: localRanges, currentIndex: localCurrent))
            .lineSpacing(mode == .dyslexia ? 8 : 6)
            .tracking(mode == .dyslexia ? 0.6 : 0.35)
            .textSelection(.enabled)
            // One element per paragraph for VoiceOver — never word-by-word hops
            // through the attributed runs of the visual highlight.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(paragraph.text)
    }

    private func attributed(_ source: String, wordRanges: [Range<Int>], currentIndex: Int?) -> AttributedString {
        var result = AttributedString()
        let runs = KaraokeTextFormatter.runs(
            text: source, wordRanges: wordRanges, currentIndex: currentIndex, bionic: mode == .bionic
        )
        for run in runs {
            if run.boldPrefix > 0 {
                result += piece(String(run.text.prefix(run.boldPrefix)), phase: run.phase, bold: true)
                result += piece(String(run.text.dropFirst(run.boldPrefix)), phase: run.phase, bold: false)
            } else {
                result += piece(String(run.text), phase: run.phase, bold: run.phase == .current)
            }
        }
        return result
    }

    private func piece(_ string: String, phase: KaraokePhase, bold: Bool) -> AttributedString {
        guard !string.isEmpty else { return AttributedString() }
        var piece = AttributedString(string)
        piece.font = bold ? baseFont.bold() : baseFont
        switch phase {
        case .spoken:
            piece.foregroundColor = .primary
        case .current:
            piece.foregroundColor = .primary
            piece.backgroundColor = Color.accentColor.opacity(0.32)
        case .upcoming:
            piece.foregroundColor = Color.primary.opacity(0.45)
        }
        return piece
    }

    private var baseFont: Font {
        switch mode {
        case .standard, .bionic: .system(size: 19)
        case .serif: .system(size: 19, design: .serif)
        case .dyslexia: .dyslexic(20)
        }
    }
}
