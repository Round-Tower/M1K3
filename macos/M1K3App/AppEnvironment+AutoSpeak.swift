//
//  AppEnvironment+AutoSpeak.swift
//  M1K3
//
//  Chat auto-speak (Kev, 2026-08-13): with the toggle on, M1K3 speaks its
//  answers IN THE CHAT SURFACE, sentence-by-sentence as they stream, while the
//  karaoke band above the input bar follows the spoken words — reading and
//  listening at the same time, without entering voice mode.
//
//  The session is the voice adapter's sentence-streaming shape (poll the
//  @Observable message, fold forward, speak serially) with the fold-forward
//  guard now shared via StreamedAnswerFolder rather than duplicated. Speaking
//  goes through `speak(_:)`, which polishes for speech (markdown flattened —
//  the #93 lesson) and feeds SpeechHighlight, so the karaoke band works with
//  zero new plumbing.
//
//  Lifecycle rules:
//  • One session at a time — a new send supersedes the old (stop + cancel):
//    typing IS the barge-in.
//  • Never during voice-first mode (the loop owns speech) — checked at start
//    AND each poll tick, so entering the mode mid-answer goes quiet too.
//  • The toggle is live: flipping it off mid-answer stops the voice on the
//    next tick (the UI also stops current speech directly, for immediacy).
//  • A failed turn speaks nothing further — the error earcon carries it.
//
//  Signed: Kev + claude-fable-5, 2026-08-13, Confidence 0.8 (glue over
//  test-pinned folder/polish/highlight seams; the felt beat — does hearing
//  every answer delight or grate — is Kev's ⌘R to settle). Prior: Unknown.

import Foundation
import M1K3Chat
import M1K3Inference
import M1K3Voice

extension AppEnvironment {
    /// Whether a send should start an auto-speak session right now.
    var autoSpeakWouldServe: Bool {
        VoiceModeDefaults.autoSpeakEnabled && !VoiceModeDefaults.isActive
    }

    /// Begin speaking the answer to the send that is about to stream. Call
    /// BEFORE `chat.send` so the baseline pins this turn's assistant message
    /// (the same never-read-`messages.last` rule as the voice adapter —
    /// a delegate_deep delivery must not be spoken as this answer).
    func beginAutoSpeakSession() {
        guard autoSpeakWouldServe else { return }
        // A send while a turn is already streaming NO-OPS in ChatSession
        // (`guard !isResponding`), so starting a session here would cancel the
        // in-flight answer's speech and pin a baseline no message will ever
        // cross — leave the live session alone instead (review catch, PR #124;
        // reachable via dictation, whose mic button doesn't disable mid-turn).
        guard !chat.isResponding else { return }
        let superseding = autoSpeakTask != nil
        cancelAutoSpeak()
        let baselineCount = chat.messages.count
        autoSpeakTask = Task { @MainActor [weak self] in
            // Typing is the barge-in: silence a superseded session's in-flight
            // utterance BEFORE this one speaks, sequenced inside this task so
            // the stop can't race past and kill the new answer's first line.
            if superseding { await self?.stopSpeaking() }
            var folder = StreamedAnswerFolder(stopMarker: FollowUpSplit.sentinel)
            var pinnedID: UUID?
            // Poll ticks before the first assistant message appears; ~10s at
            // 150ms. Generous — a message normally appears within one tick.
            let firstMessageTickBudget = 66
            var ticks = 0

            /// Nested funcs in a @MainActor closure are NONISOLATED by default
            /// (Swift 6) — the annotation is load-bearing, not decoration.
            @MainActor func pinnedMessage() -> ChatMessage? {
                guard let self else { return nil }
                if let pinnedID { return self.chat.messages.first { $0.id == pinnedID } }
                guard self.chat.messages.count > baselineCount else { return nil }
                let candidate = self.chat.messages[baselineCount...].first { $0.role == .assistant }
                pinnedID = candidate?.id
                return candidate
            }

            while !Task.isCancelled {
                guard let self, self.autoSpeakWouldServe else { return }
                let message = pinnedMessage()
                if let message {
                    // Speaking inside the poll loop IS the serial drain: the
                    // next fold happens after this sentence finishes, and the
                    // cumulative ingest picks up everything streamed meanwhile.
                    for sentence in folder.ingest(message.text) {
                        guard !Task.isCancelled else { return }
                        await self.speak(sentence)
                    }
                    switch message.status {
                    case .failed:
                        return // the error earcon carries it; speak nothing more
                    case .complete:
                        // The loop above already ingested the settled text —
                        // only the unterminated tail remains.
                        if !Task.isCancelled, let tail = folder.flush() {
                            await self.speak(tail)
                        }
                        return
                    default:
                        break // still streaming
                    }
                } else if ticks > firstMessageTickBudget {
                    // No assistant message ever crossed the baseline — a send
                    // that silently no-opped somewhere this file can't see.
                    // Give up rather than spin every 150ms indefinitely.
                    return
                }
                ticks += 1
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Stop the session and any speech it started. Safe to call when idle.
    func cancelAutoSpeak() {
        autoSpeakTask?.cancel()
        autoSpeakTask = nil
    }
}
