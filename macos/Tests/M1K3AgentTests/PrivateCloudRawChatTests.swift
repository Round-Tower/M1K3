//
//  PrivateCloudRawChatTests.swift
//  M1K3AgentTests
//
//  Pins what a lent Private Cloud Compute call carries and returns: the
//  caller's own system text and turns and nothing else, deltas from cumulative
//  snapshots, one finish, and each failure under a name a client can act on.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.85, Prior: none (new file).
//

import Foundation
import M1K3Agent
import M1K3Inference
import M1K3LanguageModel
import Synchronization
import Testing

private final class RecordingCloud: PrivateCloudAnswering {
    let snapshots: [String]
    let failure: PrivateCloudFailure?
    private let calls = Mutex<[(instructions: String, prompt: String)]>([])

    init(snapshots: [String], failure: PrivateCloudFailure? = nil) {
        self.snapshots = snapshots
        self.failure = failure
    }

    var seen: [(instructions: String, prompt: String)] {
        calls.withLock { $0 }
    }

    func status() async -> PrivateCloudStatus {
        PrivateCloudStatus(available: true, quota: .belowLimit)
    }

    func answer(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
        calls.withLock { $0.append((instructions, prompt)) }
        let snapshots = snapshots, failure = failure
        return AsyncThrowingStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            if let failure {
                continuation.finish(throwing: PrivateCloudError(failure))
            } else {
                continuation.finish()
            }
        }
    }
}

private func collect(_ stream: RawChatStream) async throws -> (text: String, finishes: [RawChatFinish]) {
    var text = ""
    var finishes: [RawChatFinish] = []
    for try await event in stream {
        switch event {
        case let .delta(piece): text += piece
        case let .finished(finish): finishes.append(finish)
        }
    }
    return (text, finishes)
}

struct PrivateCloudRawChatTests {
    @Test("The caller's system text follows the acceptable-use rule, and its one question is the prompt: nothing else is added")
    func carriesOnlyTheCallersWords() async throws {
        let cloud = RecordingCloud(snapshots: ["Hi."])
        let request = try RawChatRequest(
            messages: [RawChatMessage(.system, "Be brief."), RawChatMessage(.user, "Hello?")], maxTokens: nil
        )
        _ = try await collect(PrivateCloudRawChat.stream(request, backend: cloud))
        #expect(cloud.seen.count == 1)
        #expect(cloud.seen.first?.instructions == LentAppleModelGuardrail.instructions(callerSystem: "Be brief."))
        #expect(cloud.seen.first?.instructions.hasSuffix("Be brief.") == true)
        #expect(cloud.seen.first?.prompt == "Hello?")
    }

    @Test("No system message means the rule alone, and earlier turns ride in the prompt, labelled")
    func flattensEarlierTurns() async throws {
        let cloud = RecordingCloud(snapshots: ["4"])
        let request = try RawChatRequest(messages: [
            RawChatMessage(.user, "What is 1+1?"), RawChatMessage(.assistant, "2"), RawChatMessage(.user, "Double it."),
        ], maxTokens: nil)
        _ = try await collect(PrivateCloudRawChat.stream(request, backend: cloud))
        #expect(cloud.seen.first?.instructions == LentAppleModelGuardrail.rule)
        #expect(cloud.seen.first?.prompt == RawChatPrompt.flattened(request))
        #expect(cloud.seen.first?.prompt.contains("Assistant: 2") == true)
    }

    @Test("Cumulative snapshots become deltas, then exactly one finish with no token counts")
    func snapshotsBecomeDeltas() async throws {
        let cloud = RecordingCloud(snapshots: ["He", "Hello", "Hello there."])
        let request = try RawChatRequest(messages: [RawChatMessage(.user, "Hi")], maxTokens: nil)
        let result = try await collect(PrivateCloudRawChat.stream(request, backend: cloud))
        #expect(result.text == "Hello there.")
        #expect(result.finishes == [RawChatFinish(reason: .stop, promptTokens: nil, completionTokens: nil)])
    }

    @Test("A failure throws under a name a client can act on, after any text that arrived", arguments: [
        (PrivateCloudFailure.rateLimited, RawChatFailure.busy),
        (.network, .unavailable),
        (.unavailable, .unavailable),
        (.quotaLimitReached(resetsAt: nil), .limitReached),
        (.other, .failed),
    ])
    func failuresAreNamed(failure: PrivateCloudFailure, expected: RawChatFailure) async throws {
        let cloud = RecordingCloud(snapshots: ["Par"], failure: failure)
        let request = try RawChatRequest(messages: [RawChatMessage(.user, "Hi")], maxTokens: nil)
        var text = ""
        do {
            for try await event in PrivateCloudRawChat.stream(request, backend: cloud) {
                if case let .delta(piece) = event { text += piece }
            }
            Issue.record("the stream finished without throwing")
        } catch {
            #expect(error as? RawChatFailure == expected)
        }
        #expect(text == "Par")
    }

    @Test("A backend that ends with no text is a failure, never an empty success")
    func emptyStreamIsAFailure() async throws {
        let cloud = RecordingCloud(snapshots: [])
        let request = try RawChatRequest(messages: [RawChatMessage(.user, "Hi")], maxTokens: nil)
        await #expect(throws: RawChatFailure.failed) {
            _ = try await collect(PrivateCloudRawChat.stream(request, backend: cloud))
        }
    }

    @Test("A cancellation on the backend's side, with this caller still listening, is a failure and not a whole answer")
    func backendCancellationIsAFailure() async throws {
        struct CancellingCloud: PrivateCloudAnswering {
            func status() async -> PrivateCloudStatus {
                PrivateCloudStatus(available: true, quota: .belowLimit)
            }

            func answer(instructions _: String, prompt _: String) -> AsyncThrowingStream<String, any Error> {
                AsyncThrowingStream { continuation in
                    continuation.yield("Half an")
                    continuation.finish(throwing: CancellationError())
                }
            }
        }
        let request = try RawChatRequest(messages: [RawChatMessage(.user, "Hi")], maxTokens: nil)
        await #expect(throws: RawChatFailure.failed) {
            _ = try await collect(PrivateCloudRawChat.stream(request, backend: CancellingCloud()))
        }
    }

    @Test("An offer that cannot serve refuses with its reason, and a refused stream throws it at once")
    func refusals() async {
        #expect(PrivateCloudRawChat.refusal(for: .ready) == nil)
        #expect(PrivateCloudRawChat.refusal(for: .unavailable) == .unavailable)
        #expect(PrivateCloudRawChat.refusal(for: .exhausted(resetsAt: nil)) == .limitReached)
        #expect(PrivateCloudRawChat.refusal(for: .notOffered) == .notOffered)
        await #expect(throws: RawChatFailure.limitReached) {
            for try await _ in PrivateCloudRawChat.refused(.limitReached) {}
        }
    }

    @Test("A whole answer for a tool call is the last snapshot")
    func askReturnsTheLastSnapshot() async throws {
        let cloud = RecordingCloud(snapshots: ["A", "An answer."])
        let answer = try await PrivateCloudRawChat.ask(prompt: "Q", instructions: "I", backend: cloud)
        #expect(answer == "An answer.")
        #expect(cloud.seen.first?.instructions == LentAppleModelGuardrail.instructions(callerSystem: "I"))
        #expect(cloud.seen.first?.prompt == "Q")
    }

    @Test("A tool call that fails throws the cloud's own failure, so the caller can be told why")
    func askThrowsTheFailure() async {
        let cloud = RecordingCloud(snapshots: [], failure: .quotaLimitReached(resetsAt: nil))
        await #expect(throws: PrivateCloudError(.quotaLimitReached(resetsAt: nil))) {
            _ = try await PrivateCloudRawChat.ask(prompt: "Q", instructions: "", backend: cloud)
        }
    }
}
