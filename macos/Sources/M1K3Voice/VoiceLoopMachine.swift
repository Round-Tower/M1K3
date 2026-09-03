//
//  VoiceLoopMachine.swift
//  M1K3Voice
//
//  The pure reducer behind voice-first mode's hands-free conversation loop:
//  listen → endpoint → run the turn → speak the answer → listen again. Events
//  in, commands out, zero side effects — VoiceLoopController executes the
//  commands against the real mic/chat/speech seams.
//
//  Design rules pinned by the tests:
//  • Half-duplex: the mic is never armed while thinking or speaking (no echo).
//  • Re-listens after speech carry an echo grace (speaker tail audio).
//  • Two consecutive empty listens park the mic — no infinite re-arm loop.
//  • Stale events in the wrong state are dropped (the late speechFinished a
//    barge-in's stop() produces; an answerReady landing after exit).
//  • exit is terminal and never cancels the in-flight turn — the answer still
//    lands in the chat transcript, it just isn't spoken.
//  • pause parks from ANY active state (the OS took the audio session: a call,
//    headphones pulled) and, like exit, never cancels the turn — the answer
//    lands unspoken; begin re-arms. Unlike mute it also stops speech.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.9 (pure, every
//  transition test-pinned). Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-03 — `.pause` added for iOS audio
//  interruptions (AudioInterruptionPolicy); five transitions pinned.
//  Review: Kev + claude-fable-5, 2026-09-03 — the empty-listen budget is an init
//  parameter (was a private static 2) so the conversational cadence can keep the
//  mic awake through a quiet spell. Default unchanged; the 2-listen pin still holds.
//

import Foundation

public enum VoiceLoopState: Equatable, Sendable {
    /// Mode active, mic parked (muted, gave up after empty listens, or an error).
    case idle
    case listening(partial: String)
    case awaitingAnswer(question: String)
    case speaking(answer: String)
    /// Terminal — the mode was exited.
    case ended
}

public enum VoiceLoopEvent: Equatable, Sendable {
    /// Enter the mode / tap-to-talk from a parked idle.
    case begin
    /// Cumulative live transcript while listening.
    case partial(String)
    /// The utterance ended (recognizer finality or silence endpoint).
    case endpointed(String)
    /// The COMPLETE answer at once (legacy non-streaming path).
    case answerReady(String)
    /// One speakable sentence of a still-streaming answer (2026-07-25:
    /// sentence-streamed speech — first audio at the first sentence, not
    /// after the whole generation).
    case answerChunk(String)
    /// The streaming turn finished generating (chunks may still be speaking).
    case answerCompleted
    case answerFailed(String)
    /// Natural TTS completion (onSpeakingEnded).
    case speechFinished
    /// User barge-in (click/Space while speaking).
    case interrupt
    /// Park the mic without leaving the mode.
    case mute
    /// The audio session was taken away (interruption / route loss): stop
    /// whichever direction is live and park. Not terminal — begin re-arms.
    case pause
    case exit
}

public enum VoiceLoopCommand: Equatable, Sendable {
    /// `afterEchoGrace` delays arming the mic briefly so the speaker tail of
    /// the just-finished utterance isn't transcribed.
    case startListening(afterEchoGrace: Bool)
    case stopListening
    case runTurn(String)
    case speak(String)
    case stopSpeaking
}

public struct VoiceLoopMachine: Sendable {
    public private(set) var state: VoiceLoopState = .idle
    /// Park after this many empty listens in a row.
    private var consecutiveEmptyListens = 0
    /// The budget above. The default (2) is dictation-shaped; a conversational
    /// cadence feeds a far larger one (EndpointCadence.emptyListensBeforeParking,
    /// 2026-09-03) so a quiet spell can't turn a hands-free mode into tap-to-talk.
    private let maxEmptyListens: Int
    /// Sentence-streaming bookkeeping: utterances enqueued but not yet ended.
    /// The loop re-listens only when this drains AND generation finished —
    /// speechFinished arrives once per spoken chunk (the speech provider fires
    /// onSpeakingEnded per utterance).
    private var unspokenChunks = 0
    /// True once the streaming turn stopped producing (completed OR failed).
    private var generationDone = false

    public init(maxEmptyListens: Int = 2) {
        precondition(maxEmptyListens >= 1, "the loop must be allowed at least one empty listen")
        self.maxEmptyListens = maxEmptyListens
    }

    public mutating func handle(_ event: VoiceLoopEvent) -> [VoiceLoopCommand] {
        if case .ended = state { return [] }
        switch event {
        case .begin:
            guard case .idle = state else { return [] }
            state = .listening(partial: "")
            return [.startListening(afterEchoGrace: false)]

        case let .partial(text):
            guard case .listening = state else { return [] }
            state = .listening(partial: text)
            return []

        case let .endpointed(text):
            guard case .listening = state else { return [] }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return emptyListenEnded() }
            consecutiveEmptyListens = 0
            unspokenChunks = 0
            generationDone = false
            state = .awaitingAnswer(question: trimmed)
            return [.stopListening, .runTurn(trimmed)]

        case let .answerReady(answer):
            guard case .awaitingAnswer = state else { return [] }
            // Legacy whole-answer path ≡ one chunk + completion.
            unspokenChunks = 1
            generationDone = true
            state = .speaking(answer: answer)
            return [.speak(answer)]

        case let .answerChunk(chunk):
            switch state {
            case .awaitingAnswer:
                unspokenChunks = 1
                generationDone = false
                state = .speaking(answer: chunk)
                return [.speak(chunk)]
            case let .speaking(answer):
                unspokenChunks += 1
                state = .speaking(answer: answer.isEmpty ? chunk : answer + " " + chunk)
                return [.speak(chunk)]
            case .idle, .listening, .ended:
                return [] // stale (barge-in/exit already moved on)
            }

        case .answerCompleted:
            switch state {
            case .awaitingAnswer:
                // Generation ended with zero speakable chunks — park, mirroring
                // answerFailed (the controller surfaces any error separately).
                state = .idle
                return []
            case .speaking:
                generationDone = true
                return relistenIfDrained()
            case .idle, .listening, .ended:
                return []
            }

        case .answerFailed:
            switch state {
            case .awaitingAnswer:
                state = .idle
                return []
            case .speaking:
                // A failure after chunks already spoke: let the queued audio
                // finish naturally, then re-listen — same shape as completion.
                generationDone = true
                return relistenIfDrained()
            case .idle, .listening, .ended:
                return []
            }

        case .speechFinished:
            guard case .speaking = state else { return [] }
            unspokenChunks = max(0, unspokenChunks - 1)
            return relistenIfDrained()

        case .interrupt:
            guard case .speaking = state else { return [] }
            state = .listening(partial: "")
            return [.stopSpeaking, .startListening(afterEchoGrace: true)]

        case .mute:
            switch state {
            case .listening:
                state = .idle
                return [.stopListening]
            case .idle, .awaitingAnswer, .speaking, .ended:
                return []
            }

        case .pause:
            switch state {
            case .listening:
                state = .idle
                return [.stopListening]
            case .speaking:
                // Later chunks / completion of the still-running generator
                // land in idle and are dropped as stale — same shape as exit.
                state = .idle
                return [.stopSpeaking]
            case .awaitingAnswer:
                state = .idle
                return []
            case .idle, .ended:
                return []
            }

        case .exit:
            state = .ended
            return [.stopSpeaking, .stopListening]
        }
    }

    /// Speaking → listening only when the last queued utterance ended AND the
    /// generator stopped; anything else keeps speaking with no commands.
    private mutating func relistenIfDrained() -> [VoiceLoopCommand] {
        guard unspokenChunks == 0, generationDone else { return [] }
        state = .listening(partial: "")
        return [.startListening(afterEchoGrace: true)]
    }

    private mutating func emptyListenEnded() -> [VoiceLoopCommand] {
        consecutiveEmptyListens += 1
        if consecutiveEmptyListens >= maxEmptyListens {
            state = .idle
            return [.stopListening]
        }
        state = .listening(partial: "")
        return [.stopListening, .startListening(afterEchoGrace: false)]
    }
}
