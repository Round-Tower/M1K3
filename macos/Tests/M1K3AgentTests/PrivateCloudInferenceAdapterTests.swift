//
//  PrivateCloudInferenceAdapterTests.swift
//  M1K3AgentTests
//
//  Pins the PCC column's adapter with a fake backend: cumulative snapshots are
//  kept (generate) and re-yielded (generateStreaming), the persona rides as the
//  instructions, and a failed stream names its reason instead of reading empty.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.9. Prior: Unknown
//

import Foundation
import M1K3Agent
import M1K3Inference
import M1K3LanguageModel
import Synchronization
import Testing

/// A backend that streams the snapshots it was given, or fails after `n` of them.
private struct FakeCloud: PrivateCloudAnswering {
    let snapshots: [String]
    var failAfter: Int? = nil
    let seen = SeenInstructions()

    func status() async -> PrivateCloudStatus {
        PrivateCloudStatus(available: true, quota: .belowLimit)
    }

    func answer(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
        seen.record(instructions: instructions, prompt: prompt)
        return AsyncThrowingStream { continuation in
            for (i, s) in snapshots.enumerated() {
                if let failAfter, i == failAfter {
                    continuation.finish(throwing: PrivateCloudError(.quotaLimitReached(resetsAt: nil)))
                    return
                }
                continuation.yield(s)
            }
            continuation.finish()
        }
    }
}

private final class SeenInstructions: Sendable {
    private let calls = Mutex<[(String, String)]>([])
    func record(instructions: String, prompt: String) {
        calls.withLock { $0.append((instructions, prompt)) }
    }

    var last: (String, String)? {
        calls.withLock { $0.last }
    }
}

struct PrivateCloudInferenceAdapterTests {
    @Test("generate keeps the LAST cumulative snapshot")
    func generateKeepsTheLastSnapshot() async throws {
        let adapter = PrivateCloudInferenceAdapter(backend: FakeCloud(snapshots: ["H", "He", "Hel", "Hello."]))
        #expect(try await adapter.generate(prompt: "hi") == "Hello.")
    }

    @Test("generateStreaming re-yields the snapshots as-is, and folding them gives the answer")
    func streamingReyieldsSnapshots() async {
        let adapter = PrivateCloudInferenceAdapter(backend: FakeCloud(snapshots: ["H", "He", "Hel"]))
        var pieces: [String] = []
        var folded = ""
        for await piece in adapter.generateStreaming(prompt: "hi") {
            pieces.append(piece)
            folded = StreamFold.fold(current: folded, chunk: piece)
        }
        #expect(pieces == ["H", "He", "Hel"])
        #expect(folded == "Hel")
        #expect(adapter.takeStreamFailure() == nil)
    }

    @Test("the persona rides as instructions and the adapter says it carries it")
    func personaAsInstructions() async throws {
        let fake = FakeCloud(snapshots: ["ok"])
        let adapter = PrivateCloudInferenceAdapter(backend: fake, instructions: { "PERSONA" })
        _ = try await adapter.generate(prompt: "the question")
        #expect(fake.seen.last?.0 == "PERSONA")
        #expect(fake.seen.last?.1 == "the question")
        #expect(adapter.carriesStandingPersona)
        #expect(adapter.name == "pcc" && PrivateCloudInferenceAdapter.modelID == "apple/private-cloud-compute")
    }

    @Test("a stream that fails ends quietly but names its reason once")
    func failedStreamNamesItsReason() async {
        let adapter = PrivateCloudInferenceAdapter(backend: FakeCloud(snapshots: ["H", "He"], failAfter: 1))
        var pieces: [String] = []
        for await piece in adapter.generateStreaming(prompt: "hi") {
            pieces.append(piece)
        }
        #expect(pieces == ["H"])
        let reason = adapter.takeStreamFailure()
        #expect(reason?.contains("quotaLimitReached") == true)
        #expect(adapter.takeStreamFailure() == nil, "cleared on read")
    }

    @Test("generate propagates the backend's error")
    func generateThrows() async {
        let adapter = PrivateCloudInferenceAdapter(backend: FakeCloud(snapshots: ["H"], failAfter: 0))
        await #expect(throws: PrivateCloudError.self) {
            _ = try await adapter.generate(prompt: "hi")
        }
    }
}
