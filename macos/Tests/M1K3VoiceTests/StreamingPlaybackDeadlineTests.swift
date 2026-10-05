//
//  StreamingPlaybackDeadlineTests.swift
//  M1K3VoiceTests
//
//  The bounded completion wait, driven headless with an injected sleeper — no
//  audio hardware, no wall clock. The hardware path (a BLE headset whose IO
//  buffer outgrows the engine's max frames) stays verify-by-launch.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-02, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-10-02 (PR #471 round 2) — pins that a late
//  .dataPlayedBack after a timed-out cancel is inert (it could otherwise stop() the NEXT
//  utterance's playback on the shared player). Confidence now 0.85.

import AVFoundation
@testable import M1K3Voice
import Testing

/// A sleeper the test fires by hand. Records the requested duration; throws
/// CancellationError if the sleeping task is cancelled first.
private actor ManualSleeper {
    private(set) var requested: [Duration] = []
    private var sleepers: [CheckedContinuation<Void, Error>] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        for waiter in requestWaiters {
            waiter.resume()
        }
        requestWaiters = []
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { sleepers.append($0) }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    func waitUntilRequested() async {
        if !requested.isEmpty { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func fire() {
        let pending = sleepers
        sleepers = []
        for sleeper in pending {
            sleeper.resume()
        }
    }

    private func cancelAll() {
        let pending = sleepers
        sleepers = []
        for sleeper in pending {
            sleeper.resume(throwing: CancellationError())
        }
    }
}

@MainActor
struct StreamingPlaybackDeadlineTests {
    private func makeSession() -> StreamingPlaybackSession {
        StreamingPlaybackSession(player: AVAudioPlayerNode(), sampleRate: 24000, onTimeline: { _ in }, onWord: { _ in })
    }

    @Test("a wait whose completion never arrives times out after duration plus grace")
    func timesOut() async {
        let session = makeSession()
        session.accountScheduled(sampleCount: 48000) // 2 s at 24 kHz
        session.markStreamEnded()
        let sleeper = ManualSleeper()

        let waiter = Task { @MainActor in
            await session.awaitCompletion(policy: PlaybackDeadlinePolicy(grace: .seconds(3))) {
                try await sleeper.sleep($0)
            }
        }
        await sleeper.waitUntilRequested()
        #expect(await sleeper.requested == [.seconds(5)])
        await sleeper.fire()

        #expect(await waiter.value == .timedOut)
        #expect(session.isCancelled)
    }

    @Test("a completion arriving before the deadline wins and abandons the sleeper")
    func completesInTime() async {
        let session = makeSession()
        session.accountScheduled(sampleCount: 24000)
        session.markStreamEnded()
        let sleeper = ManualSleeper()

        let waiter = Task { @MainActor in
            await session.awaitCompletion(policy: PlaybackDeadlinePolicy()) { try await sleeper.sleep($0) }
        }
        await sleeper.waitUntilRequested()
        session.bufferCompleted()

        #expect(await waiter.value == .completed)
        #expect(session.isCancelled == false)
    }

    @Test("a cancel (stop) resolves the wait as cancelled, not timed out")
    func cancelled() async {
        let session = makeSession()
        session.accountScheduled(sampleCount: 24000)
        session.markStreamEnded()
        let sleeper = ManualSleeper()

        let waiter = Task { @MainActor in
            await session.awaitCompletion(policy: PlaybackDeadlinePolicy()) { try await sleeper.sleep($0) }
        }
        await sleeper.waitUntilRequested()
        session.cancel()

        #expect(await waiter.value == .cancelled)
    }

    @Test("nothing pending returns completed immediately without sleeping")
    func nothingPending() async {
        let session = makeSession()
        session.markStreamEnded()
        let sleeper = ManualSleeper()
        let outcome = await session.awaitCompletion(policy: PlaybackDeadlinePolicy()) { try await sleeper.sleep($0) }
        #expect(outcome == .completed)
        #expect(await sleeper.requested.isEmpty)
    }

    @Test("late buffer completions after a timed-out cancel are inert")
    func lateCompletionAfterTimeout() async {
        let session = makeSession()
        session.accountScheduled(sampleCount: 24000)
        session.accountScheduled(sampleCount: 24000)
        session.markStreamEnded()
        let sleeper = ManualSleeper()
        let waiter = Task { @MainActor in
            await session.awaitCompletion(policy: PlaybackDeadlinePolicy()) { try await sleeper.sleep($0) }
        }
        await sleeper.waitUntilRequested()
        await sleeper.fire()
        #expect(await waiter.value == .timedOut)
        #expect(session.teardownCount == 1)

        // The engine rebuild can flush both pending completions after the fact. Each
        // is one decrement against a buffer that was scheduled, so the debug assert
        // cannot trip — but the LAST one must not tear the shared player down again.
        session.bufferCompleted()
        session.bufferCompleted()
        #expect(session.teardownCount == 1)
    }
}
