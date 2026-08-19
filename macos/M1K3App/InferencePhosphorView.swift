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
    @State private var rain = InferencePhosphor()
    /// Chars already rained per message id, so a growing reasoning/answer
    /// string feeds only its new tail — never re-stacks what's on screen.
    @State private var consumed: [String: (reasoning: Int, answer: Int)] = [:]
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
        let lineHeight: CGFloat = 22
        // Newest sits low (just under the avatar's chin third); older rises.
        let baseline = size.height * 0.72
        let font = Font.system(size: 13, weight: .medium, design: .monospaced)

        for (index, line) in lines.enumerated() {
            let opacity = rain.opacity(for: line, at: now)
            guard opacity > 0.01 else { continue }
            // Stack from the baseline upward by arrival order, plus the age
            // rise so each line keeps drifting up as newer ones arrive.
            let stack = CGFloat(lines.count - 1 - index) * lineHeight
            let rise = reduceMotion ? 0 : CGFloat(rain.rise(for: line, at: now, riseHeight: 40))
            let y = baseline - stack - rise
            guard y > -lineHeight, y < size.height else { continue }

            var text = canvas.resolve(Text(line.text).font(font))
            text.shading = .color(line.source.tint.opacity(opacity * 0.85))
            canvas.draw(text, at: CGPoint(x: size.width / 2, y: y), anchor: .center)
        }
    }

    // MARK: - Feed (M1K3's OWN output only — verbatim, delta-fed)

    private func feed(now: Date) {
        rain.prune(at: now)
        guard let message = activeMessage else {
            lastActivity = nil
            return
        }
        let id = message.id.uuidString
        var marks = consumed[id] ?? (0, 0)

        // Tool activity: a discrete label — rain it once when it changes.
        if let label = message.activityLabel, label != lastActivity {
            rain.ingestOwn(label, source: .tool, at: now)
            lastActivity = label
        }

        // Reasoning: the growing <think> stream — feed its new tail.
        if let reasoning = message.reasoning, reasoning.count > marks.reasoning {
            feedTail(of: reasoning, from: &marks.reasoning, source: .thinking, now: now)
        }
        // Answer: rain a light sampling of the tokens as they stream.
        if message.reasoning == nil || message.reasoning?.isEmpty == true {
            if message.text.count > marks.answer {
                feedTail(of: message.text, from: &marks.answer, source: .answer, now: now)
            }
        }
        consumed[id] = marks
        // Bound the per-message ledger — only the in-flight message matters.
        if consumed.count > 8 {
            consumed = [id: marks]
        }
    }

    /// Rain the new suffix of a growing string in fragment-sized pieces,
    /// advancing the consumed cursor so nothing rains twice.
    private func feedTail(of full: String, from cursor: inout Int, source: PhosphorSource, now: Date) {
        let chars = Array(full)
        guard cursor < chars.count else { return }
        // Fragment on word boundaries within the new tail, capped so a burst
        // doesn't dump the whole stream in one tick.
        let tail = String(chars[cursor...])
        let words = tail.split(separator: " ", omittingEmptySubsequences: true)
        var buffer = ""
        var fed = 0
        for word in words {
            if buffer.count + word.count + 1 > 40 {
                if !buffer.isEmpty { rain.ingestOwn(buffer, source: source, at: now); fed += 1 }
                buffer = String(word)
            } else {
                buffer += buffer.isEmpty ? String(word) : " \(word)"
            }
            if fed >= 3 { break } // at most a few lines per tick — a rain, not a flood
        }
        if !buffer.isEmpty, fed < 3 { rain.ingestOwn(buffer, source: source, at: now) }
        cursor = chars.count
    }
}
