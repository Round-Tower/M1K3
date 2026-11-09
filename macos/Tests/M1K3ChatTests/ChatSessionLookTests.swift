//
//  ChatSessionLookTests.swift
//  M1K3ChatTests
//
//  One look through the real ChatSession (#768), against a fake pair of eyes.
//  What these pin, end to end:
//  - the frame rides on the user's message and the eyes get exactly the look
//    prompt: no persona, no history, no grounding;
//  - the responder is never asked, so no tool (web search included) can run on
//    a turn that carries what the camera saw;
//  - the answer is tagged `look`, which keeps it out of distilled memory;
//  - a decline is said in one honest line that never replays as history, a
//    failure mid-answer keeps what came, and a stop with nothing leaves no
//    hollow bubble.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.85 (fakes on both
//  sides; the camera, Lil and Mini are verify-by-launch on the phone).
//  Prior: none (new file)
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

/// Records every look; streams the scripted cumulative snapshots, then either
/// finishes or throws the scripted error.
private final class FakeEyes: ImageLooking, @unchecked Sendable {
    struct Call: Equatable {
        let image: ImageAttachment
        let instructions: String
        let prompt: String
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    let snapshots: [String]
    let failure: (any Error)?

    init(snapshots: [String], failure: (any Error)? = nil) {
        self.snapshots = snapshots
        self.failure = failure
    }

    var received: [Call] {
        lock.withLock { calls }
    }

    func look(image: ImageAttachment, instructions: String, prompt: String) -> LookStream {
        lock.withLock { calls.append(Call(image: image, instructions: instructions, prompt: prompt)) }
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

/// Eyes that stream on demand and hold the turn open until the consumer goes
/// away. Records the teardown: that is the hook a real brain cancels from.
private final class SteppedEyes: ImageLooking, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?
    private var terminated = false

    var started: Bool {
        lock.withLock { continuation != nil }
    }

    var wasTerminated: Bool {
        lock.withLock { terminated }
    }

    func look(image _: ImageAttachment, instructions _: String, prompt _: String) -> LookStream {
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        continuation.onTermination = { [lock] _ in
            lock.withLock { self.terminated = true }
        }
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func yield(_ snapshot: String) {
        _ = lock.withLock { continuation?.yield(snapshot) }
    }
}

/// The local agent. Counts calls so a test can prove a look never reaches it.
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
struct ChatSessionLookTests {
    private let frame = ImageAttachment(url: URL(fileURLWithPath: "/tmp/look-frame.jpg"))

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a look puts the frame on the question and streams the answer, tagged, without the responder")
    func lookAnswers() async {
        let responder = CountingResponder()
        let session = ChatSession(responder: responder)
        session.residentBrainName = { "Lil" }
        let eyes = FakeEyes(snapshots: ["A shopfront", "A shopfront on Thomas Street."])

        await session.look("What does the sign say?", frame: frame, looker: eyes)

        #expect(session.messages.count == 2)
        let question = session.messages.first
        #expect(question?.role == .user)
        #expect(question?.text == "What does the sign say?")
        #expect(question?.attachments == [frame])
        let answer = session.messages.last
        #expect(answer?.role == .assistant)
        #expect(answer?.text == "A shopfront on Thomas Street.")
        #expect(answer?.status == .complete)
        #expect(answer?.toolsUsed == [LookPrompt.toolName])
        #expect(answer?.brain == "Lil")
        #expect(answer?.interrupted == nil)
        #expect(answer?.activityLabel == nil)
        #expect(!session.isResponding)
        #expect(responder.callCount == 0)
        #expect(eyes.received == [
            .init(image: frame, instructions: LookPrompt.instructions, prompt: "What does the sign say?"),
        ])
    }

    @Test("a look with no words asks the default question")
    func blankQuestionAsksTheDefault() async {
        let session = ChatSession(responder: CountingResponder())
        let eyes = FakeEyes(snapshots: ["A kettle."])

        await session.look("  \n", frame: frame, looker: eyes)

        #expect(session.messages.first?.text == LookPrompt.defaultQuestion)
        #expect(eyes.received.first?.prompt == LookPrompt.defaultQuestion)
    }

    @Test("what the camera saw is never distilled into memory, but stays in the conversation")
    func lookAnswerIsNotDistilled() async {
        let session = ChatSession(responder: CountingResponder())
        await session.look("What is this?", frame: frame, looker: FakeEyes(snapshots: ["A prescription label."]))

        let distillable = ChatSession.distillableTurns(session.messages[...])
        #expect(distillable.map(\.text) == ["What is this?"])
        let replayed = ChatSession.replayableHistory(session.messages)
        #expect(replayed.map(\.text) == ["What is this?", "A prescription label."])
    }

    @Test("a decline is said in the brain's own honest line, and never replays as history")
    func declineIsSaidOnce() async {
        let session = ChatSession(responder: CountingResponder())
        let eyes = FakeEyes(snapshots: [], failure: LookDeclined(reply: "I couldn't make that out."))

        await session.look("What is this?", frame: frame, looker: eyes)

        let answer = session.messages.last
        #expect(answer?.text == "I couldn't make that out.")
        #expect(answer?.status == .complete)
        #expect(answer?.contextExcluded == true)
        #expect(answer?.toolsUsed == [LookPrompt.toolName])
        #expect(ChatSession.replayableHistory(session.messages).map(\.text) == ["What is this?"])
    }

    @Test("a brain with no eyes says so, rather than asking the user to try again")
    func blindBrainSaysSo() async {
        let session = ChatSession(responder: CountingResponder())
        let eyes = FakeEyes(snapshots: [], failure: ImageLookingError.cannotLook)

        await session.look("What is this?", frame: frame, looker: eyes)

        #expect(session.messages.last?.text == LookFailureReply.cannotSee)
        #expect(session.messages.last?.contextExcluded == true)
    }

    @Test("any other failure before a word asks for another go")
    func failureBeforeAnyText() async {
        struct Boom: Error {}
        let session = ChatSession(responder: CountingResponder())

        await session.look("What is this?", frame: frame, looker: FakeEyes(snapshots: [], failure: Boom()))

        #expect(session.messages.last?.text == LookFailureReply.tryAgain)
        #expect(session.messages.last?.contextExcluded == true)
        #expect(!session.isResponding)
    }

    @Test("an answer that comes back empty is not shown as an empty bubble")
    func emptyAnswerAsksForAnotherGo() async {
        let session = ChatSession(responder: CountingResponder())

        await session.look("What is this?", frame: frame, looker: FakeEyes(snapshots: []))

        #expect(session.messages.last?.text == LookFailureReply.tryAgain)
        #expect(session.messages.last?.contextExcluded == true)
    }

    @Test("a failure mid-answer keeps what came, marked as cut short")
    func failureMidAnswerKeepsThePartial() async {
        struct Boom: Error {}
        let session = ChatSession(responder: CountingResponder())
        let eyes = FakeEyes(snapshots: ["A red door"], failure: Boom())

        await session.look("What is this?", frame: frame, looker: eyes)

        let answer = session.messages.last
        #expect(answer?.text == "A red door")
        #expect(answer?.interrupted == true)
        #expect(answer?.status == .complete)
        #expect(answer?.toolsUsed == [LookPrompt.toolName])
    }

    @Test("stop mid-look keeps the partial answer and tears the eyes down")
    func stopKeepsPartial() async {
        let session = ChatSession(responder: CountingResponder())
        let eyes = SteppedEyes()
        let looking = Task { await session.look("What is this?", frame: frame, looker: eyes) }
        await waitUntil { eyes.started }
        eyes.yield("A bicycle")
        await waitUntil { session.messages.last?.text == "A bicycle" }
        #expect(session.isResponding)

        session.stopResponding()
        await looking.value

        let answer = session.messages.last
        #expect(answer?.text == "A bicycle")
        #expect(answer?.interrupted == true)
        #expect(answer?.status == .complete)
        #expect(!session.isResponding)
        #expect(eyes.wasTerminated)
    }

    @Test("stop before a word removes the empty bubble but keeps the question and its frame")
    func stopBeforeAnyTextLeavesNoHollowBubble() async {
        let session = ChatSession(responder: CountingResponder())
        let eyes = SteppedEyes()
        let looking = Task { await session.look("What is this?", frame: frame, looker: eyes) }
        await waitUntil { eyes.started }

        session.stopResponding()
        await looking.value

        #expect(session.messages.count == 1)
        #expect(session.messages.first?.attachments == [frame])
        #expect(!session.isResponding)
    }

    @Test("a look while a turn is in flight is a no-op, and says so to the caller")
    func reentrantLookIsRefused() async {
        let session = ChatSession(responder: CountingResponder())
        let eyes = SteppedEyes()
        let looking = Task { await session.look("first", frame: frame, looker: eyes) }
        await waitUntil { eyes.started }

        let second = FakeEyes(snapshots: ["never"])
        let ran = await session.look("second", frame: frame, looker: second)

        #expect(!ran)
        #expect(second.received.isEmpty)
        #expect(session.messages.count(where: { $0.role == .user }) == 1)
        session.stopResponding()
        #expect(await looking.value)
    }

    @Test("the turn after a look is an ordinary one, and the next look still works")
    func latchDrops() async {
        let responder = CountingResponder()
        let session = ChatSession(responder: responder)
        await session.look("What is this?", frame: frame, looker: FakeEyes(snapshots: ["A mug."]))

        await session.send("Thanks")

        #expect(responder.callCount == 1)
        #expect(session.messages.count == 4)
        #expect(session.messages.last?.toolsUsed == nil)
    }
}

struct LookPromptTests {
    @Test("the instructions hold the brain to what is in view")
    func instructionsStayOnTheFrame() {
        #expect(LookPrompt.instructions.contains("Say only what you can see"))
        #expect(LookPrompt.instructions.count < 400)
    }

    @Test("a question is trimmed, and a blank one becomes the default")
    func questionFallsBack() {
        #expect(LookPrompt.question("  What colour is it?\n") == "What colour is it?")
        #expect(LookPrompt.question("") == LookPrompt.defaultQuestion)
        #expect(LookPrompt.question(" \t ") == LookPrompt.defaultQuestion)
    }

    @Test("the look tag is tainted, so a look never becomes a memory")
    func lookIsTainted() {
        #expect(DistillationTaint.isTainted(toolsUsed: [LookPrompt.toolName]))
        #expect(DistillationTaint.taintedToolNames.contains("look"))
    }

    @Test("the transcript names the camera, not a snake_case tool")
    func traceLabel() {
        #expect(ActivityLabeler.traceLabel(for: [LookPrompt.toolName]) == "Used the camera")
    }
}
