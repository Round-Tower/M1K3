//
//  ThinkAsideTests.swift
//  M1K3ChatTests
//
//  "The Tell" (2026-11-20): when a speed-tier brain decides a turn needs real thought, M1K3 says so in one
//  plain line before the long quiet, instead of a bare spinner for ~35 s. Pinned here: the lines are honest
//  (nothing in them can be measured against the wait), they rotate, and the line rides the answer as a
//  transient caption that a reasoning chunk keeps and the first answer text clears.
//
//  Signed: claude-opus-5-5, 2026-11-20, Confidence 0.75 (the rules are pinned; whether the line makes a
//  35 s think feel like work is a hands-on read, not a test). Prior: none (new file).
//  Review: Kev + claude-opus-5-5, 2026-11-20 — pins the 6 s spoken delay (Kev took the steer). Confidence 0.8.
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

struct ThinkAsideRulesTests {
    @Test("every line is short, whole, and makes no claim the wait could disprove")
    func linesAreHonest() {
        // No numbers, durations or progress: nothing reads the think's length. Not "puzzle" either: the
        // line also fires on explain / compare / debug asks and Always mode. No villain words: the look
        // is the villain, never the voice.
        let banned = ["almost", "nearly", "second", "minute", "moment", "quick", "%", "puzzle",
                      "scheme", "plot", "minion", "mwah"]
        #expect(ThinkAside.lines.count >= 4)
        for line in ThinkAside.lines {
            #expect(!line.isEmpty)
            #expect(line.count <= 48, "\(line)")
            #expect(line.last == ".", "a whole sentence: \(line)")
            let hasDigit = line.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
            #expect(!hasDigit, "\(line)")
            for word in banned {
                #expect(!line.lowercased().contains(word), "\(line) says \(word)")
            }
        }
        #expect(Set(ThinkAside.lines).count == ThinkAside.lines.count, "no duplicate lines")
    }

    @Test("the lines rotate: two thinks in a row never say the same thing, and every line gets its turn")
    func linesRotate() {
        let count = ThinkAside.lines.count
        let said = (0 ..< count * 2).map { ThinkAside.line(forThink: $0) }
        for (earlier, later) in zip(said, said.dropFirst()) {
            #expect(earlier != later)
        }
        #expect(Set(said.prefix(count)) == Set(ThinkAside.lines))
        #expect(ThinkAside.line(forThink: -1) == ThinkAside.lines[0], "a bad index falls back, never traps")
    }

    @Test("the spoken line waits for a real quiet: a think that answers inside the delay is never announced aloud")
    func spokenOnlyAfterRealQuiet() {
        // Kev, 2026-11-20: say it when the quiet is real, not when it's predicted.
        #expect(ThinkAside.spokenDelay == .seconds(6))
        #expect(!ThinkAside.shouldSay(shownFor: .zero))
        #expect(!ThinkAside.shouldSay(shownFor: .milliseconds(5999)))
        #expect(ThinkAside.shouldSay(shownFor: .seconds(6)))
        #expect(ThinkAside.shouldSay(shownFor: .seconds(40)))
    }

    @Test("the activity is never the in-flight label: the label stays the plain Thinking…")
    func deliberatingLabel() {
        #expect(ActivityLabeler.label(for: .deliberating) == ActivityLabeler.label(for: .thinking(iteration: 0)))
    }
}

/// A turn that says it will think, then streams a reasoning chunk, then the answer, each on cue.
private final class GatedDeliberatingResponder: RAGResponding, @unchecked Sendable {
    private var continuation: AsyncStream<String>.Continuation?

    func answerStreaming(
        _ question: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, history: [], onActivity: { _ in })
    }

    func answerStreaming(
        _: String,
        history _: [ChatTurn],
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.continuation = continuation
        onActivity(.deliberating)
        return ([], stream)
    }

    func think() {
        continuation?.yield("<think>The bat costs a dollar more than the ball")
    }

    func answer() {
        continuation?.yield("</think>The ball costs 5 cents.")
        continuation?.finish()
    }
}

@MainActor
struct ThinkAsideSessionTests {
    /// Polls the main actor until `condition` holds (the activity hops ride `Task { @MainActor }`).
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("the aside lands on the answer as a caption, survives the reasoning, and goes with the first answer text")
    func asideLifecycle() async throws {
        let responder = GatedDeliberatingResponder()
        let session = ChatSession(responder: responder)
        let send = Task { await session.send("A bat and a ball cost 1.10 in total. How much is the ball?") }
        try await waitUntil { session.messages.last?.thinkAside != nil }
        let deliberating = try #require(session.messages.last)
        #expect(deliberating.thinkAside == ThinkAside.line(forThink: 0))
        #expect(deliberating.activityLabel == nil, "the aside never stands in as the in-flight label")
        #expect(deliberating.text.isEmpty, "never part of the answer text")

        responder.think()
        try await waitUntil { session.messages.last?.reasoning != nil }
        #expect(session.messages.last?.thinkAside == ThinkAside.line(forThink: 0), "the think keeps it")

        responder.answer()
        await send.value
        let answer = try #require(session.messages.last)
        #expect(answer.text.contains("5 cents"))
        #expect(answer.thinkAside == nil, "the answer replaces it")
        #expect(!ChatSession.replayableHistory(session.messages).map(\.text).joined().contains(ThinkAside.lines[0]))
    }

    @Test("the next think says the next line")
    func asideRotatesAcrossTurns() async throws {
        let responder = GatedDeliberatingResponder() // each send takes a fresh stream from it
        let session = ChatSession(responder: responder)
        var seen: [String] = []
        for turn in 0 ..< 2 {
            let send = Task { await session.send("question \(turn)") }
            try await waitUntil { session.messages.last?.role == .assistant && session.messages.last?.thinkAside != nil }
            try seen.append(#require(session.messages.last?.thinkAside))
            responder.answer()
            await send.value
        }
        #expect(seen == [ThinkAside.line(forThink: 0), ThinkAside.line(forThink: 1)])
    }

    @Test("the aside is never persisted: a transcript round trip drops it")
    func asideIsTransient() throws {
        var message = ChatMessage(role: .assistant, text: "", status: .streaming)
        message.thinkAside = ThinkAside.lines[0]
        let roundTrip = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(roundTrip.thinkAside == nil)
    }
}
