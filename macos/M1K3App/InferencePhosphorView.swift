//
//  InferencePhosphorView.swift
//  M1K3App
//
//  The "thinking rain": M1K3's live inference scrolling up behind the avatar
//  in voice mode — reasoning, tool activity, and answer tokens as phosphor
//  text on a CRT. Transparency as aesthetic, the anti-black-box.
//
//  The ledger + the own-vs-visitor privacy split are the pure, TDD'd
//  `InferencePhosphor` (M1K3Avatar). This is the Canvas that paints it,
//  mirroring CRTOverlay's TimelineView idiom (elapsed-since-start clock, 30fps,
//  non-interactive, a11y-hidden). It feeds the rain from the live `@Observable`
//  ChatSession the scout mapped: `reasoning` / `activityLabel` / `text` on the
//  in-flight assistant message — all M1K3's OWN output, shown verbatim.
//
//  Visitor glyphs (a paired Brain-at-Home device / MCP caller raining derived
//  marks) ride the `mcpLogRevision` counter — a named follow-up, landing when
//  the heartbeat-timeline PR's observable revision merges. The seam
//  (`InferencePhosphor.ingestVisitor`) is built and tested; only the live
//  wiring waits.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.8 (the fold is
//  TDD'd; this view is verify-by-launch — the rain's FEEL over a live thinking
//  turn is Kev's eye). Prior: the data-rain seed (project-memory 2026-08-06).
//

import M1K3Avatar
import M1K3Chat
import SwiftUI

/// Phosphor tint per source — all in the CRT green-cyan family so the rain
/// reads as one tube, with just enough hue to tell thought from tool from
/// answer. Visitor is a dim grey-green (backgrounded, never foreground text).
extension PhosphorSource {
    var tint: Color {
        switch self {
        case .thinking: Color(red: 0.45, green: 1.0, blue: 0.72) // calm phosphor green
        case .tool: Color(red: 0.55, green: 0.9, blue: 1.0) // cyan ping
        case .answer: Color(red: 0.78, green: 1.0, blue: 0.88) // bright green-white
        case .visitor: Color(red: 0.55, green: 0.72, blue: 0.66) // dim, derived
        }
    }
}

struct InferencePhosphorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Elapsed-time origin (the CRTOverlay / AudioCaptureBackdrop precision
    /// lesson — never an absolute reference date).
    @State private var start = Date()
    /// Longer TTL / fewer lines than the default — ambient, not a ticker.
    @State private var rain = InferencePhosphor(maxLines: 7, fragmentCap: 64, lineTTL: 9)
    /// Chars already consumed per message id, so a growing reasoning/answer
    /// string feeds only its new tail — never re-reads what's flushed.
    @State private var consumed: [String: (reasoning: Int, answer: Int)] = [:]
    /// Partial phrase still accumulating per source — flushed as ONE line on a
    /// clause/sentence boundary (or when it gets long), so the rain reads as
    /// phrases, not one word per line.
    @State private var buffer: [PhosphorSource: String] = [:]
    @State private var lastActivity: String?

    /// The in-flight assistant message whose live fields drive the rain.
    private var activeMessage: ChatMessage? {
        guard env.chat.isResponding, let last = env.chat.messages.last,
              last.role == .assistant
        else { return nil }
        return last
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let now = context.date
            Canvas { canvas, size in
                draw(canvas, size: size, now: now)
            }
            // Feed inside the timeline tick so a poll-based ChatSession update
            // (the 150ms voice poller) is picked up without a push seam.
            .onChange(of: context.date) { _, _ in feed(now: now) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .drawingGroup() // one offscreen layer — text over a bright avatar is cheap this way
    }

    // MARK: - Draw

    private func draw(_ canvas: GraphicsContext, size: CGSize, now: Date) {
        let lines = rain.active(at: now)
        guard !lines.isEmpty else { return }
        // Large + ambient: a few big phrases surfacing and dissolving, not a
        // dense ticker. Line height scales with the surface.
        let fontSize = max(20, min(34, size.height / 26))
        let lineHeight = fontSize * 1.7
        // Centred vertically so lines rise THROUGH the middle and fade out the
        // top — the avatar floats in front of them (this layer is behind it).
        let baseline = size.height * 0.62
        let font = Font.system(size: fontSize, weight: .light, design: .monospaced)

        for (index, line) in lines.enumerated() {
            let opacity = rain.opacity(for: line, at: now)
            guard opacity > 0.01 else { continue }
            let stack = CGFloat(lines.count - 1 - index) * lineHeight
            let rise = reduceMotion ? 0 : CGFloat(rain.rise(for: line, at: now, riseHeight: size.height * 0.22))
            let y = baseline - stack - rise
            guard y > -lineHeight, y < size.height + lineHeight else { continue }

            var text = canvas.resolve(Text(line.text).font(font))
            // Ambient: capped well below full so it reads as a backdrop the
            // avatar sits in front of, never foreground text.
            text.shading = .color(line.source.tint.opacity(opacity * 0.5))
            canvas.draw(text, at: CGPoint(x: size.width / 2, y: y), anchor: .center)
        }
    }

    // MARK: - Feed (M1K3's OWN output only — verbatim, delta-fed)

    private func feed(now: Date) {
        rain.prune(at: now)
        guard let message = activeMessage else {
            lastActivity = nil
            buffer = [:]
            return
        }
        let id = message.id.uuidString
        var marks = consumed[id] ?? (0, 0)

        // Tool activity: a discrete label — rain it once as its own phrase.
        if let label = message.activityLabel, label != lastActivity {
            rain.ingestOwn(label, source: .tool, at: now)
            lastActivity = label
        }

        // Reasoning: the growing <think> stream — accumulate its new tail into
        // phrases, flush a whole line on a clause boundary.
        if let reasoning = message.reasoning, reasoning.count > marks.reasoning {
            accumulate(of: reasoning, from: &marks.reasoning, source: .thinking, now: now)
        }
        // Answer: same phrasing when there's no separate reasoning stream.
        if message.reasoning == nil || message.reasoning?.isEmpty == true {
            if message.text.count > marks.answer {
                accumulate(of: message.text, from: &marks.answer, source: .answer, now: now)
            }
        }
        consumed[id] = marks
        // Bound the per-message ledger — only the in-flight message matters.
        if consumed.count > 8 {
            consumed = [id: marks]
        }
    }

    /// Where a phrase can break — clause/sentence punctuation. A line flushes
    /// at the FIRST of these at/after ~24 chars, so lines read as phrases
    /// ("of mist that clings to your coat") rather than one word each.
    private static let breakChars: Set<Character> = [".", ",", ";", ":", "!", "?", "—", "\n"]
    private static let minPhrase = 24
    private static let maxPhrase = 64

    /// Fold the new suffix of a growing string into `buffer[source]`, flushing
    /// a full phrase-line whenever it reaches a clause boundary or the cap.
    private func accumulate(of full: String, from cursor: inout Int, source: PhosphorSource, now: Date) {
        let chars = Array(full)
        guard cursor < chars.count else { return }
        var pending = buffer[source] ?? ""
        for ch in chars[cursor...] {
            pending.append(ch)
            let atBreak = Self.breakChars.contains(ch) && pending.trimmingCharacters(in: .whitespaces).count >= Self.minPhrase
            if atBreak || pending.count >= Self.maxPhrase {
                rain.ingestOwn(pending, source: source, at: now)
                pending = ""
            }
        }
        buffer[source] = pending
        cursor = chars.count
    }
}
