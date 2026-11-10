//
//  LookFollowUpTests.swift
//  M1K3ChatTests
//
//  What comes after a look (#768 follow-ups), against fake eyes:
//  - the PASS gate: with the eye open the brain may say the question is not
//    about the view; nothing reaches the transcript until it has started a
//    real answer, and a passed turn leaves no trace;
//  - a second question about the SAME frame (`lookAgain`) is a look too: on
//    the device, no responder, display-only, the earlier exchange in its prompt;
//  - the turn straight after a look withholds the web unless its own words ask
//    for a search (the 2026-11-09 spike sent "Is there a person in the
//    picture?" to a search engine);
//  - what a look knows (the date and time) rides in its instructions;
//  - a search query is drafted on the device and cleaned before anyone sees it.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-10, Confidence 0.85 (fakes on both
//  sides; the brains' real PASS behaviour is scored apart, on a blind set).
//  Prior: none (new file)
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

private final class ScriptedEyes: ImageLooking, @unchecked Sendable {
    struct Call: Equatable {
        let image: ImageAttachment
        let instructions: String
        let prompt: String
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var scripts: [[String]]
    let failure: (any Error)?

    init(_ scripts: [String]..., failure: (any Error)? = nil) {
        self.scripts = scripts
        self.failure = failure
    }

    var received: [Call] {
        lock.withLock { calls }
    }

    func look(image: ImageAttachment, instructions: String, prompt: String) -> LookStream {
        let snapshots: [String] = lock.withLock {
            calls.append(Call(image: image, instructions: instructions, prompt: prompt))
            return scripts.isEmpty ? [] : scripts.removeFirst()
        }
        let failure = failure
        return AsyncThrowingStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish(throwing: failure)
        }
    }
}

/// Eyes that stream on demand, so a test can read the transcript mid-answer.
private final class HeldEyes: ImageLooking, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?

    var started: Bool {
        lock.withLock { continuation != nil }
    }

    func look(image _: ImageAttachment, instructions _: String, prompt _: String) -> LookStream {
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func yield(_ snapshot: String) {
        _ = lock.withLock { continuation?.yield(snapshot) }
    }

    func finish() {
        lock.withLock { continuation?.finish() }
    }
}

/// The local agent: records, per ordinary turn, whether the web was withheld
/// (read where a real responder builds its tool palette) and the history.
private final class WebWatchingResponder: RAGResponding, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []
    private var histories: [[ChatTurn]] = []
    var withheld: [Bool] {
        lock.withLock { seen }
    }

    var receivedHistories: [[ChatTurn]] {
        lock.withLock { histories }
    }

    func answerStreaming(_ question: String) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, history: [], onActivity: { _ in })
    }

    func answerStreaming(
        _: String,
        history: [ChatTurn],
        onActivity _: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        let withheld = LookAftermath.withholdsWeb
        lock.withLock {
            seen.append(withheld)
            histories.append(history)
        }
        return ([], AsyncStream { continuation in
            continuation.yield("Sure.")
            continuation.finish()
        })
    }
}

@MainActor
struct LookFollowUpTests {
    private let frame = ImageAttachment(url: URL(fileURLWithPath: "/tmp/look-frame.jpg"))

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 3000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    // MARK: - The PASS gate

    @Test("the gate holds while the answer could still be the word, and reads the final answer")
    func gateReadings() {
        for held in ["", " ", "P", "pa", "PAS", "PASS", "\"PASS", "Pass."] {
            #expect(LookPassGate.reading(of: held) == .undecided, "\(held.debugDescription)")
        }
        for answering in ["A", "Passengers", "PASSED", "A sign", "Pa pa"] {
            #expect(LookPassGate.reading(of: answering) == .answering, "\(answering.debugDescription)")
        }
        for passed in ["PASS", "pass", "Pass.", " \"PASS\" ", "PASS\n", "Remind me to call the dentist. PASS."] {
            #expect(LookPassGate.passed(passed), "\(passed.debugDescription)")
        }
        for answered in ["", "A boarding pass.", "Passengers waiting", "PASSPORT", "You may pass", "A sign that says PASSING"] {
            #expect(!LookPassGate.passed(answered), "\(answered.debugDescription)")
        }
    }

    @Test("a passed turn leaves no trace: no message, nothing persisted to replay, and the caller is told")
    func passLeavesNoTrace() async {
        let session = ChatSession(responder: WebWatchingResponder())
        let eyes = ScriptedEyes(["P", "PASS"])

        let verdict = await session.lookIfAboutTheView("What's the weather tomorrow?", frame: frame, looker: eyes)

        #expect(verdict == .passed)
        #expect(session.messages.isEmpty)
        #expect(!session.isResponding)
        #expect(eyes.received.first?.instructions == LookPrompt.instructions(mayPass: true))
        #expect(eyes.received.first?.instructions.contains("PASS") == true)
    }

    @Test("nothing reaches the transcript until the brain has started a real answer")
    func heldUntilAnAnswerStarts() async throws {
        let session = ChatSession(responder: WebWatchingResponder())
        let eyes = HeldEyes()
        let looking = Task { await session.lookIfAboutTheView("What is this?", frame: frame, looker: eyes) }
        try await waitUntil { eyes.started }
        #expect(session.messages.isEmpty)
        #expect(session.isResponding)

        eyes.yield("PA")
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.messages.isEmpty, "'PA' could still be the word")

        eyes.yield("PAINT tins on a shelf")
        try await waitUntil { session.messages.count == 2 }
        #expect(session.messages.first?.attachments == [frame])
        eyes.finish()
        #expect(await looking.value == .looked)
        #expect(session.messages.last?.text == "PAINT tins on a shelf")
        #expect(session.messages.last?.toolsUsed == [LookPrompt.toolName])
        #expect(session.messages.allSatisfy { $0.contextExcluded == true })
    }

    @Test("a late PASS takes the shown bubbles away again")
    func latePassRemovesWhatWasShown() async {
        let session = ChatSession(responder: WebWatchingResponder())
        let eyes = ScriptedEyes(["Remind me", "Remind me to call the dentist. PASS."])
        let verdict = await session.lookIfAboutTheView("Remind me to call the dentist.", frame: frame, looker: eyes)
        #expect(verdict == .passed)
        #expect(session.messages.isEmpty)
    }

    @Test("a look that may pass and fails says so as a look, like any other")
    func aFailureIsNotAPass() async {
        struct Boom: Error {}
        let session = ChatSession(responder: WebWatchingResponder())
        let eyes = ScriptedEyes([], failure: Boom())
        let verdict = await session.lookIfAboutTheView("What is this?", frame: frame, looker: eyes)
        #expect(verdict == .looked)
        #expect(session.messages.count == 2)
        #expect(session.messages.last?.text == LookFailureReply.tryAgain)
    }

    @Test("an explicit look can never pass: the word is just an answer")
    func explicitLooksNeverPass() async {
        let session = ChatSession(responder: WebWatchingResponder())
        let eyes = ScriptedEyes(["PASS"])
        #expect(await session.look("What does it say?", frame: frame, looker: eyes))
        #expect(session.messages.last?.text == "PASS")
        #expect(eyes.received.first?.instructions == LookPrompt.instructions)
        #expect(!LookPrompt.instructions.contains("PASS"))
    }

    @Test("a look in flight is busy, not a pass")
    func busyIsNotAPass() async throws {
        let session = ChatSession(responder: WebWatchingResponder())
        let held = HeldEyes()
        let first = Task { await session.look("One", frame: frame, looker: held) }
        try await waitUntil { held.started }
        #expect(await session.lookIfAboutTheView("Two", frame: frame, looker: ScriptedEyes(["x"])) == .busy)
        held.finish()
        _ = await first.value
    }

    // MARK: - Asking again about the same frame

    @Test("a second question about the same frame is a look: on the device, display-only, with the first exchange")
    func lookAgain() async {
        let responder = WebWatchingResponder()
        let session = ChatSession(responder: responder)
        let eyes = ScriptedEyes(["A red bicycle."], ["Yes, a basket on the front."])
        await session.look("What is this?", frame: frame, looker: eyes)
        #expect(session.lastLook?.frame == frame)
        #expect(session.lastLook?.question == "What is this?")
        #expect(session.lastLook?.answer == "A red bicycle.")

        #expect(await session.lookAgain("Does it have a basket?", looker: eyes))

        #expect(session.messages.count == 4)
        #expect(session.messages[2].text == "Does it have a basket?")
        #expect(session.messages[2].attachments == nil, "the frame stays on the message that took it")
        #expect(session.messages[3].text == "Yes, a basket on the front.")
        #expect(session.messages[3].toolsUsed == [LookPrompt.toolName])
        #expect(session.messages.allSatisfy { $0.contextExcluded == true })
        #expect(responder.withheld.isEmpty, "the responder is never asked")
        let second = eyes.received.last
        #expect(second?.image == frame)
        #expect(second?.instructions == LookPrompt.instructions)
        #expect(second?.prompt == LookPrompt.followUp("Does it have a basket?", after: "What is this?", answered: "A red bicycle."))
        // The chain keeps its frame: a third question still finds it.
        #expect(session.lastLook?.frame == frame)
        #expect(session.lastLook?.question == "Does it have a basket?")
    }

    @Test("there is nothing to ask again about once an ordinary turn has followed, or after a look that got no frame")
    func lookAgainNeedsTheLookToBeLast() async {
        let session = ChatSession(responder: WebWatchingResponder())
        let eyes = ScriptedEyes(["A red bicycle."], ["never"])
        #expect(session.lastLook == nil)
        #expect(await !session.lookAgain("Anything?", looker: eyes))

        await session.look("What is this?", frame: frame, looker: eyes)
        await session.send("Thanks")
        #expect(session.lastLook == nil)
        #expect(await !session.lookAgain("And the wheels?", looker: eyes))
        #expect(eyes.received.count == 1)

        let missed = ChatSession(responder: WebWatchingResponder())
        await missed.lookMissed("What is this?", saying: LookFailureReply.noFrame)
        #expect(missed.lastLook == nil)
    }

    // MARK: - The turn straight after a look

    @Test("the turn straight after a look withholds the web; the one after that does not")
    func theNextTurnWithholdsTheWeb() async {
        let responder = WebWatchingResponder()
        let session = ChatSession(responder: responder)
        await session.send("Hello")
        await session.look("What is this?", frame: frame, looker: ScriptedEyes(["A shopfront."]))
        await session.send("Is there a person in the picture?")
        await session.send("And who painted the Mona Lisa?")
        #expect(responder.withheld == [false, true, false])
        #expect(!LookAftermath.withholdsWeb, "the withhold is the turn's, not the process's")
    }

    @Test("words that ask for a search keep the web, straight after a look or not")
    func askingToSearchKeepsTheWeb() async {
        let responder = WebWatchingResponder()
        let session = ChatSession(responder: responder)
        await session.look("What is this?", frame: frame, looker: ScriptedEyes(["A Leica M6."]))
        await session.send("Search the web for Leica M6 film camera")
        #expect(responder.withheld == [false])
        for asks in ["search the web for leica m6", "Look up the Leica M6", "google leica m6", "Find it online", "look it up on the internet"] {
            #expect(LookAftermath.asksToSearch(asks), "\(asks)")
        }
        for plain in ["Is there a person in the picture?", "What colour is it?", "Thanks", "I was looking up at the sky", "research is fun"] {
            #expect(!LookAftermath.asksToSearch(plain), "\(plain)")
        }
    }

    @Test("a turn the brain passed on is the user's ordinary question: it keeps the web")
    func aPassedTurnKeepsTheWeb() async {
        let responder = WebWatchingResponder()
        let session = ChatSession(responder: responder)
        let eyes = ScriptedEyes(["A shopfront."], ["PASS"])
        await session.look("What is this?", frame: frame, looker: eyes)
        #expect(await session.lookIfAboutTheView("What's the weather tomorrow?", frame: frame, looker: eyes) == .passed)
        await session.send("What's the weather tomorrow?")
        await session.send("And the day after?")
        #expect(responder.withheld == [false, false])
        #expect(responder.receivedHistories.first?.isEmpty == true, "the look's words are still not replayed")
    }

    @Test("a missed look still asks for another, and still fences the next turn")
    func aMissedLookFencesTheNextTurn() async {
        let responder = WebWatchingResponder()
        let session = ChatSession(responder: responder)
        await session.lookMissed("What is this?", saying: LookFailureReply.noFrame)
        #expect(!session.isResponding)
        await session.send("Is it a dog?")
        #expect(responder.withheld == [true])
    }

    // MARK: - What a look knows

    @Test("the date and time ride in the instructions, after the look's own rules")
    func knowingTheDate() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Dublin") ?? .gmt
        let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15, minute: 4)) ?? .distantPast
        let line = LookGrounding.now(noon, calendar: calendar)
        #expect(line == "For reference only: it is Tuesday 10 November 2026, 15:04 for the person. Mention the date or time only if their question needs it.")

        let knowing = LookPrompt.instructions(knowing: line)
        #expect(knowing.hasPrefix(LookPrompt.instructions))
        #expect(knowing.hasSuffix(line))
        #expect(LookPrompt.instructions(knowing: "  ") == LookPrompt.instructions)
        let both = LookPrompt.instructions(knowing: line, mayPass: true)
        #expect(both.contains(line) && both.hasSuffix(LookPrompt.passClause))

        let session = ChatSession(responder: WebWatchingResponder())
        let eyes = ScriptedEyes(["In date."])
        await session.look("Is this still in date?", frame: frame, looker: eyes, knowing: line)
        #expect(eyes.received.first?.instructions == knowing)
    }

    // MARK: - The search draft

    @Test("a drafted search query is one short clean line, or nothing")
    func cleaningAQuery() {
        #expect(LookSearch.clean("Leica M6 film camera") == "Leica M6 film camera")
        #expect(LookSearch.clean("  \"Leica M6 film camera\".\n") == "Leica M6 film camera")
        #expect(LookSearch.clean("Query: Leica M6\nIt is a camera.") == "Leica M6")
        #expect(LookSearch.clean("one two three four five six seven eight nine ten eleven twelve") == "one two three four five six seven eight nine ten")
        #expect(LookSearch.clean("NONE") == nil)
        #expect(LookSearch.clean("none.") == nil)
        #expect(LookSearch.clean("   ") == nil)
        #expect(LookSearch.clean("see https://evil.example/x?q=1 now") == "see now")
        #expect(LookSearch.composerText("Leica M6 film camera") == "Search the web for Leica M6 film camera")
        #expect(LookAftermath.asksToSearch(LookSearch.composerText("anything")))
    }

    @Test("the draft is asked of the eyes with the stored frame, and adds nothing to the conversation")
    func draftingAsksTheEyes() async {
        let session = ChatSession(responder: WebWatchingResponder())
        let eyes = ScriptedEyes(["A camera."], ["Leica", "\"Leica M6 film camera\""])
        await session.look("What is this?", frame: frame, looker: eyes)
        let before = session.messages

        let draft = await session.draftLookSearch(looker: eyes)

        #expect(draft == "Leica M6 film camera")
        #expect(session.messages == before)
        #expect(eyes.received.last == .init(image: frame, instructions: LookSearch.instructions, prompt: "What is this?"))
        #expect(await ChatSession(responder: WebWatchingResponder()).draftLookSearch(looker: eyes) == nil)
    }
}
