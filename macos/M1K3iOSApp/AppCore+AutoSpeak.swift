//
//  AppCore+AutoSpeak.swift
//  M1K3iOS / M1K3visionOS
//
//  Chat auto-speak on the iPhone (Kev, 2026-10-12: "auto voice on iOS, so voice on with Kokoro"): with Settings ▸
//  Voice ▸ Speak answers on, M1K3 speaks its answers in the chat sentence by sentence as they stream, in the chosen
//  voice (M1K3 Voice is Kokoro). The Mac's twin is AppEnvironment+AutoSpeak; same key ("chat.autoSpeak"), same
//  shared seams (StreamedAnswerFolder with the persona leak guard, SpeechTextPolish, SpeechHighlight), same rules:
//  • one session at a time: a new send supersedes the old (typing is the barge-in);
//  • never in voice mode (the loop owns speech), checked at start and on every tick;
//  • the switch is live: off mid-answer goes quiet on the next tick (Settings also stops speech at once);
//  • a failed turn speaks nothing further (the error earcon carries it).
//  The phone's addition: a speech session for the answer (`.playback` / `.spokenAudio`, ducking the user's music,
//  heard on a muted phone like the voice sample), taken at the first sentence and released when the answer ends so
//  the music comes back up (AnswerAudioSessionPolicy says who may release it).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-12, Confidence 0.65 (a port of the Mac's tested-in-use loop over pinned
//  seams; how it feels on the phone is verify-on-device). Prior: AppEnvironment+AutoSpeak (Kev + claude-fable-5).
//  Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — a sentence that polishes to nothing is skipped
//  (`SpeechTextPolish.spokenSentence`): the whole-answer fallback read a streamed Source trailer's URLs aloud, which
//  is what 7ac9c1fd set out to stop. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — who owns the session. (1) A session's end is
//  generation-checked: a superseded session's late defer no longer flips its successor's Stop back to Send or releases
//  the successor's audio (it used to check only `voiceLoop`). (2) The duck starts at the first sentence, not the
//  send, so music plays on through a generation (a Lil turn can run minutes; a refused send held it ~10 s). (3) A new
//  session lets a predecessor's duck go first, in order. (4) The session helpers are the readout's and voice mode's
//  (`activateSampleAudioSession` / `deactivateVoiceAudioSession`), not a third copy. Confidence 0.7 (rules pinned in
//  AnswerAudioSessionPolicyTests; the sound is verify-by-ear on the phone, music playing).
//  Review: Kev + claude-opus-5-5, 2026-10-25 — speech stops at SpokenAnswerEnd: the follow-ups trailer OR a sources
//  header, whichever is first (voice read "Web sources:" URLs aloud line by line, Kev). Confidence 0.8.
//

import Foundation
import M1K3Chat
import M1K3Inference
import M1K3Voice

extension AppCore {
    static let spokenLeakGuard = StreamedAnswerFolder.LeakGuard(
        leaks: { PersonaLeakGuard.leaks($0) }, refusal: PersonaLeakGuard.refusal
    )

    var autoSpeakWouldServe: Bool {
        VoiceModeDefaults.autoSpeakEnabled && voiceLoop == nil
    }

    /// Begin speaking the answer to the send about to stream. Call BEFORE `chat.send`, so the baseline pins this
    /// turn's assistant message (never `messages.last`).
    func beginAutoSpeakSession() {
        guard autoSpeakWouldServe, !chat.isResponding else { return }
        let superseding = autoSpeakTask != nil
        cancelAutoSpeak()
        autoSpeakGeneration += 1
        let generation = autoSpeakGeneration
        let baselineCount = chat.messages.count
        autoSpeakTask = Task { @MainActor [weak self] in
            // Ownership by generation, not by cancellation: a superseded session's defer can run long after its
            // successor started (parked in speakAndWait until the stop resumes it), and must touch nothing then.
            defer { self?.autoSpeakSessionEnded(generation: generation) }
            if superseding { await self?.stopSpeakingAnswer() }
            // A new answer starts with the music up: a predecessor's duck is let go here, in order, before this
            // answer takes the session at its first sentence (not for the whole generation).
            await self?.releaseAnswerAudio()
            var folder = StreamedAnswerFolder(
                stopMatcher: { SpokenAnswerEnd.start(in: $0, followUps: FollowUpSplit.trailerStart(in:)) },
                leakGuard: Self.spokenLeakGuard
            )
            var pinnedID: UUID?
            let firstMessageTickBudget = 66 // ~10 s at 150 ms; a message normally appears within one tick
            var ticks = 0
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
                if let message = pinnedMessage() {
                    // Stop stays up from the answer's arrival until its last sentence (a refused send never shows it).
                    if !self.isSpeakingAnswer { self.isSpeakingAnswer = true }
                    for sentence in folder.ingest(message.text) {
                        guard !Task.isCancelled else { return }
                        await self.speakAnswerSentence(sentence)
                    }
                    switch message.status {
                    case .failed:
                        return
                    case .complete:
                        // A leak swapped for the refusal between two polls: say what the screen says.
                        if !folder.tripped, message.text == PersonaLeakGuard.refusal {
                            if !Task.isCancelled { await self.speakAnswerSentence(PersonaLeakGuard.refusal) }
                            return
                        }
                        if !Task.isCancelled, let tail = folder.flush() {
                            await self.speakAnswerSentence(tail)
                        }
                        return
                    default:
                        break
                    }
                } else if ticks > firstMessageTickBudget {
                    return
                }
                ticks += 1
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Stop the session. Safe when idle; the speech itself is stopped by `stopSpeakingAnswer`.
    func cancelAutoSpeak() {
        autoSpeakTask?.cancel()
        autoSpeakTask = nil
        isSpeakingAnswer = false
    }

    /// Stop whatever M1K3 is saying (Settings' switch, a superseding send, the stop button).
    func stopSpeakingAnswer() async {
        pendingSpeak?.cancel()
        pendingSpeak = nil
        await speech.stop()
        resumePendingSpeech()
    }

    /// One sentence, polished for speech (URLs to hosts, citation tokens dropped) and highlighted as it plays. A
    /// sentence that polishes to nothing (a Sources trailer streams in as its own) is skipped, never read raw.
    private func speakAnswerSentence(_ text: String) async {
        guard let spoken = SpeechTextPolish.spokenSentence(text) else { return }
        if !answerAudioHeld {
            // The first sentence takes the session: heard on a muted phone, the user's music ducked while M1K3
            // talks (the readout's and the sample's session). Marked held BEFORE the hop, so a stop during it
            // still releases.
            answerAudioHeld = true
            await Self.activateSampleAudioSession()
            guard !Task.isCancelled else { return }
        }
        speechHighlight.beginUtterance(text: spoken)
        await speakAndWait(spoken)
    }

    /// The session's end: finished, failed, stopped or superseded. Only the current session cleans up; a superseded
    /// one's late defer would flip its successor's Stop back to Send and pull the session out from under it.
    private func autoSpeakSessionEnded(generation: Int) {
        let isCurrent = generation == autoSpeakGeneration
        let release = AnswerAudioSessionPolicy.releaseWhenAnswerEnds(
            isCurrent: isCurrent, holdsSession: answerAudioHeld, voiceModeActive: voiceLoop != nil
        )
        guard isCurrent else { return }
        autoSpeakTask = nil
        isSpeakingAnswer = false
        // The hold ends with the answer; voice mode, if it has just taken over, keeps the session it activated.
        answerAudioHeld = false
        if release { Task { await Self.deactivateVoiceAudioSession() } }
    }

    /// Let the user's music back up, if an auto-spoken answer holds the session.
    private func releaseAnswerAudio() async {
        guard answerAudioHeld else { return }
        answerAudioHeld = false
        await Self.deactivateVoiceAudioSession()
    }
}
