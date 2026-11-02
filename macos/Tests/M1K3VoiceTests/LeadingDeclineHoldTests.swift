//
//  LeadingDeclineHoldTests.swift
//  M1K3VoiceTests
//
//  The speech half of the leading-decline drop. ChatSession folds each live snapshot through
//  `LeadingDecline.fold(_:final: false)` and every voice consumer polls the bubble into a `StreamedAnswerFolder`,
//  which skips any snapshot that is not a prefix extension. If the bubble ever showed the decline and then dropped
//  it, the decline would already be spoken and every later snapshot skipped: the answer would go silent. So the
//  fold HOLDS while the text could still be the decline. These replay growing snapshots (one character and one word
//  at a time) through the fold and the folder, the way the app's pollers do, and pin what is heard.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02, Confidence 0.85. Prior: Unknown.
//

import M1K3Inference
import M1K3Voice
import Testing

struct LeadingDeclineHoldTests {
    static let decline = M1K3Persona.taughtDecline

    static let replies: [String] = [
        "\(decline) The Berlin Wall fell in 1989. It came down in a night.",
        "\(decline)\n\nHere's today's news. Rates held, and the match was rained off.",
        decline,
        "\(decline)\nFOLLOWUPS: [\"What can you do?\"]",
        "\(decline)\n\nWeb sources:\n- example.com",
        "I don't share my wiring diagrams with strangers. Here's the gist anyway.",
        "\(decline.replacingOccurrences(of: "'", with: "\u{2019}")) It\u{2019}s four o'clock. Tea?",
        "The seal failed. It was the gasket.",
    ]

    static func snapshots(_ text: String, byWord: Bool) -> [String] {
        guard byWord else { return text.indices.map { String(text[...$0]) } }
        var out: [String] = []
        var current = ""
        for (index, piece) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            current += index == 0 ? String(piece) : " " + piece
            out.append(current)
        }
        return out
    }

    static func folder() -> StreamedAnswerFolder {
        StreamedAnswerFolder(stopMatcher: { SpokenAnswerEnd.start(in: $0, followUps: FollowUpSplit.trailerStart(in:)) })
    }

    /// What the app hears: each snapshot folded (a hold leaves the bubble as it was), polled into the folder, then
    /// the settled text and the flush.
    static func heard(_ text: String, byWord: Bool) -> (live: [String], sentences: [String], settled: String) {
        var folder = folder()
        var bubble = ""
        var live: [String] = []
        var sentences: [String] = []
        for snapshot in snapshots(text, byWord: byWord) {
            if let passed = LeadingDecline.fold(snapshot, final: false) { bubble = passed }
            live.append(bubble)
            sentences += folder.ingest(bubble)
        }
        let settled = LeadingDecline.fold(text, final: true) ?? text
        live.append(settled)
        sentences += folder.ingest(settled)
        if let tail = folder.flush() { sentences.append(tail) }
        return (live, sentences, settled)
    }

    @Test("every bubble value extends the one before, so the folder never skips one", arguments: [false, true])
    func bubbleIsPrefixMonotonic(byWord: Bool) {
        for reply in Self.replies {
            let live = Self.heard(reply, byWord: byWord).live
            for (before, after) in zip(live, live.dropFirst()) {
                #expect(after.hasPrefix(before), "\(reply.prefix(30)): \(before.debugDescription) → \(after.debugDescription)")
            }
        }
    }

    @Test("what is spoken is exactly the settled answer's sentences", arguments: [false, true])
    func spokenMatchesSettled(byWord: Bool) {
        for reply in Self.replies {
            let (_, sentences, settled) = Self.heard(reply, byWord: byWord)
            var oneShot = Self.folder()
            var expected = oneShot.ingest(settled)
            if let tail = oneShot.flush() { expected.append(tail) }
            #expect(sentences == expected, "\(reply.prefix(30))")
        }
    }

    @Test("when an answer follows, no spoken sentence carries the decline", arguments: [false, true])
    func declineNeverSpokenBeforeAnAnswer(byWord: Bool) {
        let answered = [Self.replies[0], Self.replies[1], Self.replies[6]]
        for reply in answered {
            let sentences = Self.heard(reply, byWord: byWord).sentences
            #expect(!sentences.isEmpty)
            #expect(!sentences.contains { $0.contains("not even one sentence") }, "\(sentences)")
            #expect(!sentences.contains { $0.contains("share my wiring") })
        }
    }

    @Test("a decline-only reply is spoken once, when the turn ends", arguments: [false, true])
    func declineOnlySpokenOnceAtTheEnd(byWord: Bool) {
        var folder = Self.folder()
        for snapshot in Self.snapshots(Self.decline, byWord: byWord) {
            let passed = LeadingDecline.fold(snapshot, final: false)
            #expect(passed == nil) // held the whole way: nothing on screen, nothing spoken
            if let passed { #expect(folder.ingest(passed) == []) }
        }
        let settled = LeadingDecline.fold(Self.decline, final: true) ?? ""
        var sentences = folder.ingest(settled)
        if let tail = folder.flush() { sentences.append(tail) }
        #expect(sentences.joined(separator: " ") == Self.decline)
        #expect(sentences.count { $0.contains("share my wiring") } == 1)
    }

    @Test("a reply that only looks like the decline at first is spoken whole", arguments: [false, true])
    func divergentReplySpokenWhole(byWord: Bool) {
        let sentences = Self.heard(Self.replies[5], byWord: byWord).sentences
        #expect(sentences.joined(separator: " ") == Self.replies[5])
    }
}
