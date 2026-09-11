//
//  VisitorSpeechQueue.swift
//  M1K3Voice
//
//  Per-server FIFO for MCP `speak` calls (#283): a second visitor's speak
//  while one is already in flight — ours, or something else entirely (the
//  Speak App Intent, reported through the injected `isSpeaking`) — QUEUES
//  behind it rather than cutting it, unlike EffectfulSpeechProvider's
//  deliberately newer-wins RenderEntry contract (barge-in for the voice loop
//  and for M1K3's own chat answers — neither routes through here). `speakNow`
//  is the app's existing `speak(text, narrator:)`: the HUD is stamped INSIDE
//  it, at utterance START, so a queued visitor's name appears only once its
//  turn actually plays, never at enqueue time.
//
//  Admission — the bounded-cap refusal, and appending to the wait line — is
//  synchronous within one actor-isolated call (no `await` between the cap
//  check and the append), so two `enqueue` calls racing an empty queue can
//  never both slip past the cap or both decide to play at once. `wait`
//  controls only whether the CALLER blocks for playback to finish; admission
//  itself always resolves immediately either way, mirroring the pre-existing
//  in-conversation guard (which throws before any wait/no-wait branching).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.8 (FIFO order,
//  cap refusal, and clear()-cancellation are pinned with fake speakNow/
//  isSpeaking closures; the live two-client race and the HUD re-stamp timing
//  are verify-by-launch). Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-11 (review 1 fold) — `decide` was fed
//  `!pending.isEmpty`, but the playing request has already left `pending`, so the
//  policy's `isSpeaking` never meant playback and a cap could not see the utterance
//  in flight. `isPlaying` now brackets the `speakNow` call; pinned by
//  capSeesThePlayingUtterance. The `.enqueue(position:)` payload stays unconsumed
//  (carried: nothing surfaces "you're #2" to a caller yet).
//

import Foundation

public actor VisitorSpeechQueue {
    /// One visitor `speak` call, queued to take its turn on M1K3's one voice.
    public struct SpeechRequest: Sendable {
        public let text: String
        public let emotion: String?
        public let narrator: Narrator

        public init(text: String, emotion: String?, narrator: Narrator) {
            self.text = text
            self.emotion = emotion
            self.narrator = narrator
        }
    }

    /// Thrown by `enqueue` when the wait line is already at capacity.
    public struct Full: Error, Equatable, Sendable {
        public let queued: Int
    }

    /// Thrown to a `wait: true` caller whose request was still waiting when
    /// `clear()` dropped it (`stop_speaking`).
    public struct Cancelled: Error, Equatable, Sendable {}

    public typealias SpeakNow = @Sendable (SpeechRequest) async -> Void
    public typealias IsSpeaking = @Sendable () async -> Bool

    private struct PendingJob {
        let request: SpeechRequest
        let continuation: CheckedContinuation<Void, Error>?
    }

    private let speakNow: SpeakNow
    private let externalIsSpeaking: IsSpeaking
    private let cap: Int
    private var pending: [PendingJob] = []
    private var isDraining = false
    /// True from the moment `drain` hands a request to `speakNow` until that
    /// call returns — the playing request has already left `pending`, so this
    /// is what makes `decide`'s `isSpeaking` mean playback, not the wait line.
    private var isPlaying = false

    public init(
        cap: Int = SpeakQueuePolicy.defaultCap,
        speakNow: @escaping SpeakNow,
        isSpeaking: @escaping IsSpeaking
    ) {
        self.cap = cap
        self.speakNow = speakNow
        externalIsSpeaking = isSpeaking
    }

    /// Requests waiting behind whatever is currently playing — never counts
    /// the one in flight. What `get_status`'s `queued` reports.
    public var count: Int {
        pending.count
    }

    /// Admit `request`. Throws `Full` immediately if the wait line is already
    /// at capacity (checked BEFORE the wait/no-wait branch below, so refusal
    /// is unconditional either way — the same shape as the in-conversation
    /// guard). `wait: true` returns once THIS request has actually played, or
    /// throws `Cancelled` if `clear()` dropped it first. `wait: false`
    /// returns as soon as the request is admitted; playback continues in the
    /// background — mirroring the non-queued path's `wait` semantics.
    public func enqueue(_ request: SpeechRequest, wait: Bool) async throws {
        switch SpeakQueuePolicy.decide(isSpeaking: isPlaying || !pending.isEmpty, queued: pending.count, cap: cap) {
        case let .refuse(queued):
            throw Full(queued: queued)
        case .playNow, .enqueue:
            if wait {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    pending.append(PendingJob(request: request, continuation: continuation))
                    kick()
                }
            } else {
                pending.append(PendingJob(request: request, continuation: nil))
                kick()
            }
        }
    }

    /// Drop every request still waiting — never the one already playing, which
    /// is stopped separately by the caller stopping playback itself. A
    /// `wait: true` caller still parked on its continuation is resumed with
    /// `Cancelled` rather than left hanging.
    public func clear() {
        let dropped = pending
        pending.removeAll()
        for job in dropped {
            job.continuation?.resume(throwing: Cancelled())
        }
    }

    private func kick() {
        guard !isDraining else { return }
        isDraining = true
        Task { await self.drain() }
    }

    /// Plays the wait line strictly one at a time. Re-checks `externalIsSpeaking`
    /// before each head so a request admitted into an otherwise-empty queue —
    /// because nothing of OURS was in flight — still waits out a non-queued
    /// utterance (e.g. the Speak App Intent) instead of barging over it.
    private func drain() async {
        while true {
            guard let request = pending.first?.request else {
                isDraining = false
                return
            }
            if await externalIsSpeaking() {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let job = pending.removeFirst()
            isPlaying = true
            await speakNow(request)
            isPlaying = false
            job.continuation?.resume()
        }
    }
}
