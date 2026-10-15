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
//  heard on a muted phone like the voice sample), released when the answer ends so the music comes back up.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-12, Confidence 0.65 (a port of the Mac's tested-in-use loop over pinned
//  seams; how it feels on the phone is verify-on-device). Prior: AppEnvironment+AutoSpeak (Kev + claude-fable-5).
//  Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — a sentence that polishes to nothing is skipped
//  (`SpeechTextPolish.spokenSentence`): the whole-answer fallback read a streamed Source trailer's URLs aloud, which
//  is what 7ac9c1fd set out to stop. Confidence 0.8.
//

import AVFoundation
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
        let baselineCount = chat.messages.count
        autoSpeakTask = Task { @MainActor [weak self] in
            defer {
                if let self, !Task.isCancelled { self.autoSpeakTask = nil }
                self?.isSpeakingAnswer = false
                // Let the music back up, unless voice mode has just taken the session (releasing would kill its mic).
                Task { @MainActor [weak self] in
                    guard self?.voiceLoop == nil else { return }
                    await Self.releaseAnswerAudioSession()
                }
            }
            if superseding { await self?.stopSpeakingAnswer() }
            await Self.activateAnswerAudioSession()
            self?.isSpeakingAnswer = true
            var folder = StreamedAnswerFolder(
                stopMatcher: { FollowUpSplit.trailerStart(in: $0) }, leakGuard: Self.spokenLeakGuard
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
        speechHighlight.beginUtterance(text: spoken)
        await speakAndWait(spoken)
    }

    /// Heard on a muted phone (the voice sample's session) and ducking the user's music while M1K3 talks.
    private nonisolated static func activateAnswerAudioSession() async {
        await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? session.setActive(true)
        }.value
    }

    /// The answer is over: let the user's music back up.
    private nonisolated static func releaseAnswerAudioSession() async {
        await Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }.value
    }
}
