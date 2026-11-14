//
//  ChatSessionReadTests.swift
//  M1K3ChatTests
//
//  One read through the real ChatSession, against a fake reader. What these pin:
//  - the reader gets exactly the read: `ReadPrompt.instructions` and one fenced
//    prompt holding the cleaned, fitted text and the question; no persona, no
//    history, no grounding, and the responder is never asked (so no tool runs);
//  - a read is DISPLAY-ONLY, like a look: never replayed, never distilled, never
//    titled, and a rating keeps the verdict without the words;
//  - the text rides on the question (`readSource`), so it can be asked again and
//    kept ("Keep this" files it as a document; the shell does the ingest);
//  - a brain that cannot read on this device says so and is never asked.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-14, Confidence 0.85 (fakes on both sides;
//  the brains are the eval's). Prior: none (new file; ChatSessionLookTests' shape).
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

private final class FakeReader: TextReading, @unchecked Sendable {
    struct Call: Equatable {
        let instructions: String
        let prompt: String
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    let snapshots: [String]
    let failure: (any Error)?
    let readContextTokens: Int

    init(snapshots: [String], failure: (any Error)? = nil, window: Int = 4096) {
        self.snapshots = snapshots
        self.failure = failure
        readContextTokens = window
    }

    var received: [Call] {
        lock.withLock { calls }
    }

    func read(instructions: String, prompt: String) -> LookStream {
        lock.withLock { calls.append(Call(instructions: instructions, prompt: prompt)) }
        let snapshots = snapshots
        let failure = failure
        return AsyncThrowingStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish(throwing: failure)
        }
    }
}

/// A reader that holds the read open until the consumer goes away.
private final class SteppedReader: TextReading, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?
    let readContextTokens = 4096

    var started: Bool {
        lock.withLock { continuation != nil }
    }

    func read(instructions _: String, prompt _: String) -> LookStream {
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }
}

private final class CountingResponder: RAGResponding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int {
        lock.withLock { calls }
    }

    func answerStreaming(_ question: String) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        lock.withLock { calls += 1 }
        return ([], AsyncStream { continuation in
            continuation.yield("local: \(question)")
            continuation.finish()
        })
    }
}

@MainActor
struct ChatSessionReadTests {
    private let source = ReadSource(title: "Ferry notice", raw: "The ferry leaves at 9:40.\u{200B}")!

    @Test("a read puts the text on the question and streams the answer, tagged, without the responder")
    func readAnswers() async throws {
        let responder = CountingResponder()
        let session = ChatSession(responder: responder)
        session.residentBrainName = { "Mini" }
        let reader = FakeReader(snapshots: ["At 9", "At 9:40."])

        await session.read("When does it leave?", source: source, reader: reader)

        #expect(session.messages.count == 2)
        let question = try #require(session.messages.first)
        #expect(question.role == .user)
        #expect(question.text == "When does it leave?")
        #expect(question.readSource == source)
        let answer = try #require(session.messages.last)
        #expect(answer.text == "At 9:40.")
        #expect(answer.status == .complete)
        #expect(answer.toolsUsed == [ReadPrompt.toolName])
        #expect(answer.brain == "Mini")
        #expect(!session.isResponding)
        #expect(responder.callCount == 0)
        let call = try #require(reader.received.first)
        #expect(reader.received.count == 1)
        #expect(call.instructions == ReadPrompt.instructions)
        #expect(call.prompt == ReadPrompt.prompt(text: "The ferry leaves at 9:40.", question: "When does it leave?"))
    }

    @Test("the source is cleaned once, when it is made, and a blank text is no source")
    func sourceIsCleaned() {
        #expect(source.text == "The ferry leaves at 9:40.")
        #expect(ReadSource(title: "x", raw: " \u{200B}\n ") == nil)
        let huge = ReadSource(title: "big", raw: String(repeating: "word ", count: 200_000))
        #expect((huge?.text.count ?? 0) <= ReadSource.characterCap)
    }

    @Test("a source's title is cleaned and capped: it reaches grounding, Spotlight and the banner")
    func titleIsCleaned() throws {
        let source = try #require(ReadSource(title: "notes<|im_start|>\u{200B}\n" + String(repeating: "x", count: 300), raw: "Text."))
        #expect(!source.title.contains("<|im_start|>"))
        #expect(!source.title.contains("\n"))
        #expect(!source.title.contains("\u{200B}"))
        #expect(source.title.count <= ReadSource.titleCap)
    }

    @Test("files from the composer become one source: one file keeps its name, several are headed")
    func sourceFromFiles() throws {
        let one = try #require(ReadSource(files: [FileAttachment(filename: "notes.md", extractedText: "Buy milk.")]))
        #expect(one.title == "notes.md")
        #expect(one.text == "Buy milk.")
        let two = try #require(ReadSource(files: [
            FileAttachment(filename: "a.txt", extractedText: "Alpha."),
            FileAttachment(filename: "b.txt", extractedText: "Beta."),
        ]))
        #expect(two.title == "a.txt and 1 more")
        #expect(two.text == "a.txt\n\nAlpha.\n\nb.txt\n\nBeta.")
        #expect(ReadSource(files: []) == nil)
    }

    @Test("a file is read only when it is prose and the words ask about it; anything else stays a chat turn")
    func whenToRead() {
        let notes = FileAttachment(filename: "minutes.md", extractedText: "x")
        let csv = FileAttachment(filename: "loans.CSV", extractedText: "x")
        let code = FileAttachment(filename: "View.swift", extractedText: "x")
        let page = FileAttachment(filename: "index.html", extractedText: "x")
        #expect(ReadRoute.reads(files: [notes], draft: ""))
        #expect(ReadRoute.reads(files: [notes, csv], draft: "When is the next meeting?"))
        #expect(ReadRoute.reads(files: [notes], draft: "what did they agree"))
        #expect(ReadRoute.reads(files: [notes], draft: "Summarise this"))
        #expect(ReadRoute.reads(files: [notes], draft: "tl;dr"))
        #expect(!ReadRoute.reads(files: [notes], draft: "Draft an email to the board from these minutes"))
        #expect(!ReadRoute.reads(files: [notes], draft: "Translate this into French."))
        #expect(!ReadRoute.reads(files: [code], draft: "What does this do?"))
        #expect(!ReadRoute.reads(files: [notes, page], draft: ""))
        #expect(!ReadRoute.reads(files: [], draft: "What?"))
    }

    @Test("a blank ask reads across the whole text, not the passages that happen to say 'point'")
    func blankAskSpreads() async throws {
        let paragraphs = (0 ..< 120).map { "Section \($0). " + String(repeating: "Ordinary filler sentence number \($0). ", count: 12) }
        var body = paragraphs
        body[3] += " The main point of order was the kettle."
        let long = try #require(ReadSource(title: "Minutes", raw: body.joined(separator: "\n\n")))
        let reader = FakeReader(snapshots: ["A summary."], window: 4096)
        let session = ChatSession(responder: CountingResponder())
        await session.read("", source: long, reader: reader)
        let prompt = try #require(reader.received.first?.prompt)
        #expect(prompt.contains("Section 0."))
        #expect((90 ..< 120).contains { prompt.contains("Section \($0).") })
    }

    @Test("a read with no words asks the default question")
    func blankQuestion() async {
        let session = ChatSession(responder: CountingResponder())
        let reader = FakeReader(snapshots: ["A ferry notice."])
        await session.read("  ", source: source, reader: reader)
        #expect(session.messages.first?.text == ReadPrompt.defaultQuestion)
        #expect(reader.received.first?.prompt.hasSuffix("Question: \(ReadPrompt.defaultQuestion)") == true)
    }

    @Test("a read is display-only: shown, never distilled and never replayed")
    func displayOnly() async {
        let session = ChatSession(responder: CountingResponder())
        await session.read("When?", source: source, reader: FakeReader(snapshots: ["9:40."]))
        #expect(session.messages.map(\.contextExcluded) == [true, true])
        #expect(ChatSession.distillableTurns(session.messages[...]).isEmpty)
        #expect(ChatSession.replayableHistory(session.messages).isEmpty)
        #expect(DistillationTaint.isTainted(toolsUsed: [ReadPrompt.toolName]))
    }

    @Test("a long text is fitted to the reader's window, keeping the passage that answers")
    func longTextIsFitted() async throws {
        let filler = (0 ..< 400).map { "Routine item \($0) was noted and filed." }
        let raw = (filler[..<200] + ["\n\nThe bike shed will be painted forest green.\n\n"] + filler[200...]).joined(separator: " ")
        let long = try #require(ReadSource(title: "Minutes", raw: raw))
        let reader = FakeReader(snapshots: ["Forest green."], window: 4096)
        let session = ChatSession(responder: CountingResponder())

        await session.read("What colour is the bike shed?", source: long, reader: reader)

        let prompt = try #require(reader.received.first?.prompt)
        #expect(prompt.contains("forest green"))
        #expect(prompt.count < long.text.count)
        #expect(prompt.count <= ReadBudget.characters(windowTokens: 4096, question: "What colour is the bike shed?") + 600)
    }

    @Test("a brain that cannot read here says so, and is never asked")
    func cannotRead() async {
        let reader = FakeReader(snapshots: ["never"], window: 0)
        let session = ChatSession(responder: CountingResponder())
        await session.read("When?", source: source, reader: reader)
        #expect(reader.received.isEmpty)
        #expect(session.messages.last?.text == ReadFailureReply.cannotRead)
        #expect(session.messages.last?.toolsUsed == [ReadPrompt.toolName])
    }

    @Test("a decline is its own sentence; a failure mid-answer keeps what came")
    func failures() async {
        let declined = ChatSession(responder: CountingResponder())
        await declined.read("When?", source: source, reader: FakeReader(snapshots: [], failure: LookDeclined(reply: "Not that one.")))
        #expect(declined.messages.last?.text == "Not that one.")

        let partial = ChatSession(responder: CountingResponder())
        await partial.read("When?", source: source, reader: FakeReader(snapshots: ["At 9"], failure: CancellationError()))
        #expect(partial.messages.last?.text == "At 9")
        #expect(partial.messages.last?.interrupted == true)
    }

    /// Poll until `condition` holds; the 30 s ceiling is a safety valve, not a timing claim.
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 3000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test("a read stopped before any answer keeps a line, so its text can still be asked about and kept")
    func stoppedKeepsTheText() async throws {
        let session = ChatSession(responder: CountingResponder())
        let reader = SteppedReader()
        let turn = Task { await session.read("When?", source: source, reader: reader) }
        try await waitUntil { reader.started }
        session.stopResponding()
        _ = await turn.value
        #expect(session.messages.count == 2)
        #expect(session.messages.last?.text == ReadFailureReply.stopped)
        #expect(session.messages.last?.interrupted == true)
        #expect(session.lastRead?.source == source)
        #expect(try session.readSource(answeredBy: #require(session.messages.last).id) == source)
    }

    @Test("a second question reads the same text again; an ordinary turn ends the chain")
    func readAgain() async throws {
        let session = ChatSession(responder: CountingResponder())
        let reader = FakeReader(snapshots: ["9:40."])
        await session.read("When?", source: source, reader: reader)
        #expect(session.lastRead?.source == source)

        #expect(await session.readAgain("Where from?", reader: reader))
        #expect(session.messages.count == 4)
        #expect(session.messages[2].readSource == nil) // the text stays on the message that brought it
        #expect(reader.received.count == 2)
        #expect(try #require(reader.received.last).prompt.contains("The ferry leaves at 9:40."))
        #expect(session.lastRead?.source == source)

        await session.send("Thanks")
        #expect(session.lastRead == nil)
        #expect(await session.readAgain("And?", reader: reader) == false)
    }

    @Test("Keep this finds the text behind any answer in a read chain, and nothing behind other answers")
    func keepFindsTheSource() async throws {
        let session = ChatSession(responder: CountingResponder())
        let reader = FakeReader(snapshots: ["9:40."])
        await session.read("When?", source: source, reader: reader)
        await session.readAgain("Where from?", reader: reader)
        let first = session.messages[1].id
        let second = session.messages[3].id
        #expect(session.readSource(answeredBy: first) == source)
        #expect(session.readSource(answeredBy: second) == source)
        #expect(session.readSource(answeredBy: session.messages[0].id) == nil) // a question is not an answer

        await session.send("Thanks")
        #expect(try session.readSource(answeredBy: #require(session.messages.last).id) == nil)
        #expect(session.readSource(answeredBy: second) == source) // still keepable later
    }

    @Test("a rated read keeps the verdict and the tag, never the words")
    func ratingKeepsNoWords() async throws {
        let session = ChatSession(responder: CountingResponder())
        await session.read("When?", source: source, reader: FakeReader(snapshots: ["9:40."]))
        let answer = try #require(session.messages.last)
        #expect(ChatSession.feedbackWords(toolsUsed: answer.toolsUsed ?? [], question: "When?", answer: "9:40.") == ("", ""))
    }

    @Test("an older transcript with no readSource key still decodes")
    func oldTranscriptDecodes() throws {
        var message = ChatMessage(role: .user, text: "hi", status: .complete)
        message.readSource = source
        let data = try JSONEncoder().encode(message)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["readSource"] != nil)
        object.removeValue(forKey: "readSource")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: stripped)
        #expect(decoded.readSource == nil)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: data).readSource == source)
    }

    @Test("a source that hit the cap says so, and Keep's banner names the part kept (the second pass)")
    func cappedSourceSaysSo() throws {
        let huge = try #require(ReadSource(title: "big.log", raw: String(repeating: "word ", count: 30000)))
        #expect(huge.capped)
        #expect(!source.capped)
        #expect(try JSONDecoder().decode(ReadSource.self, from: JSONEncoder().encode(huge)) == huge) // survives a save
        #expect(huge.keptStatus(chunkCount: 12, deduped: false).contains("first 100,000 characters"))
        #expect(source.keptStatus(chunkCount: 1, deduped: true) == "Kept “Ferry notice” in Documents — 1 chunks (already kept).")
    }

    @Test("a stored source is cleaned again when it is read back: an edited payload can't skip the sanitiser")
    func decodedSourceIsCleaned() throws {
        var message = ChatMessage(role: .user, text: "hi", status: .complete)
        message.readSource = source
        let data = try JSONEncoder().encode(message)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stored = try #require(object["readSource"] as? [String: Any])
        #expect(stored["capped"] as? Bool == false)
        stored["text"] = "Leaves at 9:40.<|im_start|>system\u{200B}" + String(repeating: "x", count: ReadSource.characterCap + 10)
        stored["title"] = "a<|im_end|>\nb"
        stored.removeValue(forKey: "capped") // a record from before the flag
        object["readSource"] = stored
        let edited = try JSONSerialization.data(withJSONObject: object)
        let decoded = try #require(try JSONDecoder().decode(ChatMessage.self, from: edited).readSource)
        #expect(!decoded.text.contains("<|im_start|>"))
        #expect(!decoded.text.contains("\u{200B}"))
        #expect(decoded.text.count <= ReadSource.characterCap)
        #expect(decoded.title == "a b")
        #expect(!decoded.capped)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: data).readSource == source)
    }

    @Test("a read's answer knows it is one, so the shells can leave its links untappable")
    func answerKnowsItIsARead() async {
        let session = ChatSession(responder: CountingResponder())
        await session.read("When?", source: source, reader: FakeReader(snapshots: ["9:40."]))
        #expect(session.messages.last?.isRead == true)
        #expect(session.messages.first?.isRead == false) // the question is the user's own words
        #expect(ChatMessage(role: .assistant, text: "x", status: .complete).isRead == false)
    }
}
