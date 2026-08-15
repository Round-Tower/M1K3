import Foundation
import M1K3Voice
import os
import Testing

/// Pins the finality policy that takes the turn boundary back from the
/// recognizer. The 2026-08-15 finding: on Apple Speech, `isFinal` ended the
/// stream and the stream-end fired `.endpointed` unconditionally — so the
/// recognizer's own (short, untunable) silence window owned the turn, and the
/// entire cadence stack (silence/hold/learned floor/"please") only ever ran if
/// it happened to beat Apple to the punch. WhisperKit never had the problem: it
/// only finalizes when WE stop it. The policy makes that authority explicit and
/// consumer-chosen: voice-first keeps listening through recognizer finality
/// (restarting recognition under the same session), while chat dictation and
/// the MCP listen tool keep today's ends-the-listen behaviour.
struct RecognizerFinalityTests {
    @Test("keepsListening restarts only when the listen has captured text")
    func keepsListeningRestartsOnlyWithText() {
        // Nothing captured = nothing can be cut off; a silent listen ends
        // exactly as today so the empty-listen park still works.
        #expect(FinalityPolicy.keepsListening.shouldRestart(hasCapturedText: true))
        #expect(!FinalityPolicy.keepsListening.shouldRestart(hasCapturedText: false))
    }

    @Test("endsListen never restarts")
    func endsListenNeverRestarts() {
        #expect(!FinalityPolicy.endsListen.shouldRestart(hasCapturedText: true))
        #expect(!FinalityPolicy.endsListen.shouldRestart(hasCapturedText: false))
    }

    @Test("providers without a policy-aware start fall back to plain startListening")
    func defaultStartForwardsIgnoringPolicy() throws {
        let provider = CountingProvider()
        _ = try provider.startListening(finality: .keepsListening)
        #expect(provider.startCalls.withLock { $0 } == 1)
    }
}

/// Minimal conforming fake: only the required surface, so it exercises the
/// protocol extension's default `startListening(finality:)`.
private final class CountingProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "Counting"
    let isAvailable = true
    let startCalls = OSAllocatedUnfairLock(initialState: 0)

    func startListening() throws -> AsyncStream<TranscriptSegment> {
        startCalls.withLock { $0 += 1 }
        return AsyncStream { $0.finish() }
    }

    func stopListening() {}
}
