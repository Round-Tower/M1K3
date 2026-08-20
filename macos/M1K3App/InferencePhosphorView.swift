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
        case .heartbeat: Color(red: 1.0, green: 0.82, blue: 0.5) // warm amber pulse
        case .notification: Color(red: 0.72, green: 0.68, blue: 1.0) // soft violet
        case .answer: Color(red: 0.78, green: 1.0, blue: 0.88) // (unused in the rain)
        case .visitor: Color(red: 0.55, green: 0.72, blue: 0.66) // dim, derived
        }
    }
}

struct InferencePhosphorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Low Power Mode freezes the layer entirely (the ChatBackdropTreatment
    /// contract the surrounding ZStack documents: "lowPower wins outright").
    /// Read at render like ChatBackdropTreatment does — not observable, but
    /// activity/turn changes re-render and re-read it.
    private var lowPower: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Elapsed-time origin (the CRTOverlay / AudioCaptureBackdrop precision
    /// lesson — never an absolute reference date).
    @State private var start = Date()
    /// Longer TTL / fewer lines than the default — ambient, not a ticker.
    @State private var rain = InferencePhosphor(maxLines: 7, fragmentCap: 64, lineTTL: 9)
    /// Chars already consumed per message id, so a growing reasoning/answer
    /// string feeds only its new tail — never re-reads what's flushed.
    /// Reasoning chars already consumed per message id — feeds only the new
    /// tail. (Answer is deliberately never fed; no answer cursor.)
    @State private var consumed: [String: Int] = [:]
    /// Partial phrase still accumulating per source — flushed as ONE line on a
    /// clause/sentence boundary (or when it gets long), so the rain reads as
    /// phrases, not one word per line.
    @State private var buffer: [PhosphorSource: String] = [:]
    @State private var lastActivity: String?
    /// Highest ambient-note id already rained, so `env.ambientNotes` (heartbeat
    /// pulses, later notifications/calls) each drift by exactly once. Nil until
    /// the view initialises it to the ring's CURRENT tail on first feed — so
    /// re-entering voice mode doesn't replay hours-old buffered pulses as if
    /// they just happened (review fold): only notes arriving AFTER mount rain.
    @State private var lastAmbientID: Int?

    /// The in-flight assistant message whose live fields drive the rain.
    private var activeMessage: ChatMessage? {
        guard env.chat.isResponding, let last = env.chat.messages.last,
              last.role == .assistant
        else { return nil }
        return last
    }

    var body: some View {
        // Under Low Power the TimelineView is PAUSED (no 30fps loop) — the same
        // "stay cheap" invariant AvatarSurface honours via `paused:` in this
        // ZStack. A paused timeline still renders one frame, so lingering lines
        // fade on the next real change rather than freezing mid-air forever.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: lowPower)) { context in
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

        // First feed: adopt the ring's CURRENT tail as the cursor, so the
        // notes already buffered before this view mounted do NOT replay as if
        // happening now (voice-mode re-entry burst — review fold). Only notes
        // arriving after this point rain.
        let cursor = lastAmbientID ?? (env.ambientNotes.last?.id ?? -1)
        // Ambient life — heartbeat pulses (and later notifications / call
        // transcription) drift regardless of any chat turn. Each note is a
        // complete string; split it into phrase lines once.
        for note in env.ambientNotes where note.id > cursor {
            ingestPhrases(note.text, source: note.source, now: now)
        }
        lastAmbientID = env.ambientNotes.last?.id ?? cursor

        // What M1K3 is DOING right now — tool activity + reasoning (if a brain
        // ever emits it). Deliberately NOT the answer: it already lives in the
        // chat bubble / spoken line, so raining it duplicates the output.
        guard let message = activeMessage else {
            lastActivity = nil
            buffer = [:]
            return
        }
        let id = message.id.uuidString
        var reasoningMark = consumed[id] ?? 0

        if let label = message.activityLabel, label != lastActivity {
            rain.ingestOwn(label, source: .tool, at: now)
            lastActivity = label
        }
        if let reasoning = message.reasoning, reasoning.count > reasoningMark {
            accumulate(of: reasoning, from: &reasoningMark, source: .thinking, now: now)
        }
        consumed[id] = reasoningMark
        if consumed.count > 8 {
            consumed = [id: reasoningMark]
        }
    }

    /// Split a complete string into phrase lines and rain each — for ambient
    /// notes (already whole, unlike the streaming reasoning tail).
    private func ingestPhrases(_ text: String, source: PhosphorSource, now: Date) {
        var pending = ""
        for ch in text {
            pending.append(ch)
            let atBreak = Self.breakChars.contains(ch)
                && pending.trimmingCharacters(in: .whitespaces).count >= Self.minPhrase
            if atBreak || pending.count >= Self.maxPhrase {
                rain.ingestOwn(pending, source: source, at: now)
                pending = ""
            }
        }
        if !pending.trimmingCharacters(in: .whitespaces).isEmpty {
            rain.ingestOwn(pending, source: source, at: now)
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
