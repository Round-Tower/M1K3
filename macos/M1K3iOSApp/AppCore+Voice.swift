//
//  AppCore+Voice.swift
//  M1K3iOS / M1K3visionOS
//
//  Voice-first mode's mobile adapter — the iOS sibling of the Mac's
//  AppEnvironment+VoiceMode. Builds the package-TDD'd VoiceLoopController
//  against the shell's real seams: AppleSpeechTranscriber (on-device STT),
//  AVSpeechProvider (system TTS), and `chat.send` DIRECTLY as the turn (NOT
//  `core.send` — its idle-reset would fight the loop's avatar ownership, the
//  same trap the Mac adapter documents).
//
//  Mobile-specific ground the Mac never needed:
//  • AVAudioSession — iOS/visionOS require an explicit .playAndRecord session
//    before the mic engine starts; activated on entry, released on exit. Both
//    run OFF the main actor: setActive can block for hundreds of ms while the
//    media server reconfigures (the #85 watchdog suspect).
//  • Interruptions — a call, Siri, headphones pulled, a media-services reset.
//    AudioInterruptionPolicy (pure, pinned) decides; this file only maps the
//    AVAudioSession notifications into its events and applies the action.
//  • Endpointing came from `EndpointCadence.conversational` as of 2026-08-11 —
//    shared with the Mac. This file used to carry its own gentler pair (2.0/3.5)
//    while the Mac carried 2.0/4.5, both written for the SAME complaint ("it
//    closes before the thought is done"), which is how a tuning fix could land on
//    one surface and leave the other clipping you.
//  • Sentence-streamed turns (2026-09-03): the same poller the Mac runs —
//    fold complete sentences out of the streaming assistant message and speak
//    each as it lands, so first audio arrives at the first sentence rather than
//    after the whole generation. AVSpeechProvider.speak returns as soon as the
//    utterance is QUEUED, so the speak dependency here waits for the
//    utterance's end before returning: one chunk in the synthesizer at a time,
//    and the karaoke highlight always shows the sentence being heard.
//
//  Signed: Kev + claude-fable-5, 2026-07-29, Confidence 0.75 (adapter glue over
//  the test-pinned loop/endpointer/providers; AVAudioSession behaviour, TCC
//  dialogs, and the full spoken beat are verify-by-launch on a real device —
//  the simulator has no usable mic path for this). Prior: none (new file,
//  patterned on M1K3App/AppEnvironment+VoiceMode.swift).
//  Review: Kev + claude-fable-5.1, 2026-09-03 — the voice-first pass: sentence
//  streaming + tool interstitials (ported from the Mac adapter), the karaoke
//  SpeechHighlight wiring, serialized speak, AudioInterruptionPolicy observers,
//  and off-main audio-session activation. Confidence 0.75 (compile + simulator
//  launch; the spoken beat, interruptions, and route changes are Kev's phone).
//  Same day, later: the listen stream is wrapped so a listen that ends without
//  a word reports the transcriber's `lastFailure` through `listenFailed` — the
//  loop parks with the reason on screen instead of re-arming into the wall.
//

import AVFoundation
import Foundation
import M1K3Avatar
import M1K3Chat
import M1K3Inference
import M1K3Voice
import os

extension AppCore {
    private nonisolated static let voiceLog = Logger(subsystem: "app.m1k3", category: "stt")

    var isVoiceModeActive: Bool {
        voiceLoop != nil
    }

    /// One-time wiring (from init): speech lifecycle drives the avatar's speaking
    /// state, closes the voice loop's speak step (speechDidEnd), releases the
    /// serialized speak dependency, and feeds the karaoke highlight. Outside
    /// voice mode the end callback just settles the avatar back to idle.
    func wireSpeechCallbacks() {
        speech.onSpeakingStarted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                avatar.setActivity(.speaking)
                // Same latency mark as the Mac shell — mobile is the surface
                // where the wait is felt most, so it must not be the one
                // surface that goes unmeasured.
                voiceLoop?.speechDidStart()
            }
        }
        speech.onSpeakingEnded = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                speechHighlight.clear()
                // Let the loop's drainer queue the next sentence the moment
                // this one ends (natural finish or a stop's didCancel).
                resumePendingSpeech()
                if let voiceLoop {
                    // The loop owns the next state (auto-relisten) — no idle flash.
                    voiceLoop.speechDidEnd()
                } else {
                    avatar.resetToIdle()
                }
            }
        }
        speech.onTimelineReady = { [weak self] timeline in
            Task { @MainActor [weak self] in self?.speechHighlight.apply(timeline: timeline) }
        }
        speech.onWordSpoken = { [weak self] range in
            Task { @MainActor [weak self] in self?.speechHighlight.wordSpoken(range) }
        }
    }

    /// Enter voice-first mode and start listening. Refuses while a typed turn is
    /// streaming or the brain isn't ready. Permission dialogs (mic + speech) fire
    /// naturally on the first listen; a denied grant drains the listen empty and
    /// the loop parks idle rather than looping silently.
    func enterVoiceMode() {
        guard voiceLoop == nil, !chat.isResponding, isReady else { return }
        // The responder's @Sendable budget closure cannot see `voiceLoop`, so
        // the mode announces itself through the shared defaults slot — the same
        // one the Mac shell has written since voice-first shipped.
        UserDefaults.standard.set(true, forKey: VoiceModeDefaults.activeKey)
        let controller = VoiceLoopController(
            dependencies: makeVoiceLoopDependencies(),
            cadence: .conversational
        )
        voiceLoop = controller
        voicePauseNote = nil
        installAudioSessionObservers()
        // The mic engine needs the record-capable session first; activate it off
        // the main actor and only then arm the loop. A leave in between wins.
        Task { [weak self] in
            await Self.activateVoiceAudioSession()
            guard let self, voiceLoop === controller else { return }
            controller.begin()
        }
    }

    /// Leave the mode: tears down mic + speech. An in-flight turn is NOT
    /// cancelled — its answer still lands in the chat transcript, unspoken.
    func exitVoiceMode() {
        guard let controller = voiceLoop else { return }
        controller.exit()
        voiceLoop = nil
        voicePauseNote = nil
        removeAudioSessionObservers()
        UserDefaults.standard.set(false, forKey: VoiceModeDefaults.activeKey)
        avatar.resetToIdle()
        speechHighlight.clear()
        // A speak still waiting on an utterance that will never end (stopped
        // before it started) must not hold its drainer task forever.
        resumePendingSpeech()
        Task { await Self.deactivateVoiceAudioSession() }
    }

    /// Tap-to-talk from a parked idle (also after an interruption's pause).
    func resumeVoiceListening() {
        voicePauseNote = nil
        guard let controller = voiceLoop else { return }
        // A pause can park MID-TURN (the answer lands unspoken while the turn
        // keeps running). Re-arming the mic before that turn settles would send
        // the next question into ChatSession.send's re-entrancy guard and fail
        // it as "No answer arrived" (review, 2026-09-03). Say why instead.
        guard !chat.isResponding else {
            voicePauseNote = "Finishing the last answer — tap the face again in a moment."
            return
        }
        // Same gate as enterVoiceMode: a tap inside the activation window (or
        // after a pause left the session in an unknown state) must not arm the
        // engine against a session that isn't record-capable yet. Re-activating
        // an active session is cheap (code-quality review, 2026-09-03).
        Task { [weak self] in
            await Self.activateVoiceAudioSession()
            guard let self, voiceLoop === controller else { return }
            controller.begin()
        }
    }

    // MARK: - Loop dependencies

    private func makeVoiceLoopDependencies() -> VoiceLoopController.Dependencies {
        VoiceLoopController.Dependencies(
            startListening: { [weak self] in
                guard let self else {
                    throw VoiceTurnFailure(message: "M1K3 is shutting down.")
                }
                // Voice-first owns its turn boundary: recognizer finality is a
                // segment boundary, not the end of the listen (FinalityPolicy).
                let upstream = try transcriber.startListening(finality: .keepsListening)
                avatar.setActivity(.listening)
                // Forward the segments, and when a listen ends without a word
                // ask the transcriber whether that was silence or a failure.
                // Report BEFORE finishing so the loop cancels the pending listen
                // rather than counting it empty and re-arming into the same
                // wall (2026-09-03: the simulator's recogniser failed to
                // initialise every ~170ms and the screen said nothing).
                return AsyncStream { continuation in
                    let forwarder = Task { [weak self] in
                        var sawSegments = false
                        for await segment in upstream {
                            sawSegments = true
                            continuation.yield(segment)
                        }
                        if !sawSegments, !Task.isCancelled,
                           let failure = self?.transcriber.lastFailure
                        {
                            self?.voiceLoop?.listenFailed(failure)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in forwarder.cancel() }
                }
            },
            stopListening: { [weak self] in
                self?.transcriber.stopListening()
            },
            runTurn: { [weak self] question in
                guard let self else {
                    return .failure(VoiceTurnFailure(message: "M1K3 is shutting down."))
                }
                avatar.setActivity(.thinking)
                await chat.send(question)
                guard let last = chat.messages.last, last.role == .assistant else {
                    return .failure(VoiceTurnFailure(message: "No answer arrived."))
                }
                if case let .failed(message) = last.status {
                    return .failure(VoiceTurnFailure(message: message))
                }
                guard !last.text.isEmpty else {
                    return .failure(VoiceTurnFailure(message: "The model had nothing to say."))
                }
                return .success(last.text)
            },
            speak: { [weak self] answer in
                guard let self else { return }
                // Sanitize for speech (URLs → hosts, citation tokens dropped);
                // an answer that polishes to empty is spoken raw — the loop
                // waits on a speechDidEnd that "" would never deliver.
                let polished = SpeechTextPolish.polish(answer)
                let spoken = polished.isEmpty ? answer : polished
                speechHighlight.beginUtterance(text: spoken)
                await speakAndWait(spoken)
            },
            stopSpeaking: { [weak self] in
                // A stop can run before the chunk's enqueue Task has — cancel
                // that too, or the chunk speaks AFTER "paused for the call"
                // (code-quality review, 2026-09-03).
                self?.pendingSpeak?.cancel()
                self?.pendingSpeak = nil
                await self?.speech.stop()
                // stop() before the utterance ever started yields no didCancel
                // on some OS builds — never leave the drainer parked on it.
                self?.resumePendingSpeech()
            },
            // Sentence-streamed speech: watch the assistant message WHILE
            // chat.send streams into it and fold complete sentences out
            // (StreamedAnswerFolder) — first audio at the first sentence, not
            // after the whole generation. Poll-based on purpose: ChatSession
            // already streams into the @Observable message; a 150ms cadence is
            // far below speech latency and needs no new seams. Same shape as the
            // Mac adapter, minus its Mac-only earned-moment counter.
            runTurnStreaming: { [weak self] question, onChunk in
                guard let self else {
                    return .failure(VoiceTurnFailure(message: "M1K3 is shutting down."))
                }
                avatar.setActivity(.thinking)
                // The fold-forward guard (only prefix-extending updates — a
                // FOLLOWUPS/polish shrink must never re-speak the answer).
                var folder = StreamedAnswerFolder(stopMarker: FollowUpSplit.sentinel)
                // Spoken tool transparency: each dispatch is announced once as
                // a short interstitial through the SAME onChunk lane, so it
                // inherits the serial speak queue and the turn-generation guard.
                var toolAnnouncer = ToolAnnouncementTracker()
                // Pin to THIS turn's assistant message by id — never read
                // `messages.last` (an out-of-band append would be spoken as the
                // answer). `send` appends [user, assistant] at the baseline.
                let baselineCount = chat.messages.count
                var pinnedID: UUID?
                @MainActor func foldForward(_ text: String) {
                    for sentence in folder.ingest(text) {
                        onChunk(sentence)
                    }
                }
                @MainActor func pinnedMessage() -> ChatMessage? {
                    if let pinnedID { return chat.messages.first { $0.id == pinnedID } }
                    guard chat.messages.count > baselineCount else { return nil }
                    let candidate = chat.messages[baselineCount...].first { $0.role == .assistant }
                    pinnedID = candidate?.id
                    return candidate
                }
                var announcedAnyTool = false
                @MainActor func announceTools(on message: ChatMessage) {
                    for name in toolAnnouncer.newAnnouncements(from: message.toolsUsed ?? []) {
                        announcedAnyTool = true
                        onChunk(ToolNarration.phrase(forTool: name))
                    }
                }
                let poller = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard self != nil, let message = pinnedMessage() else { continue }
                        announceTools(on: message)
                        foldForward(message.text)
                    }
                }
                await chat.send(question)
                poller.cancel()
                guard let settled = pinnedMessage() else {
                    return .failure(VoiceTurnFailure(message: "No answer arrived."))
                }
                // A tool that fired inside the final poll window is persisted
                // but was never ticked — announce it BEFORE the answer tail and
                // BEFORE a failed-turn return, so the spoken record matches the
                // visual footer either way.
                announceTools(on: settled)
                if case let .failed(message) = settled.status {
                    return .failure(VoiceTurnFailure(message: message))
                }
                foldForward(settled.text)
                if let tail = folder.flush() {
                    onChunk(tail)
                }
                guard folder.emittedAny else {
                    return .failure(VoiceTurnFailure(message: announcedAnyTool
                            ? "I checked, but no answer came back."
                            : "The model had nothing to say."))
                }
                return .success(())
            }
        )
    }

    // MARK: - Serialized speak

    /// Queue ONE utterance and return when it ends. The provider fires
    /// onSpeakingEnded once per utterance (finish or cancel), which resumes
    /// this; exit/stop paths resume it explicitly as a belt.
    private func speakAndWait(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            resumePendingSpeech() // never strand an earlier waiter
            pendingSpeechEnd = continuation
            pendingSpeak = Task { [weak self] in
                guard !Task.isCancelled else { return }
                await self?.speech.speak(text)
            }
        }
    }

    func resumePendingSpeech() {
        pendingSpeechEnd?.resume()
        pendingSpeechEnd = nil
    }

    // MARK: - Audio session (mobile-only ground)

    /// iOS/visionOS need an explicit record-capable session before AVAudioEngine
    /// can tap the mic. `.voiceChat` mode brings echo cancellation — M1K3 speaks
    /// out of the same device it listens on, and the loop's echoGrace alone
    /// can't unhear a speakerphone. Runs off the main actor (see file header).
    private nonisolated static func activateVoiceAudioSession() async {
        await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            do {
                #if os(iOS)
                    try session.setCategory(
                        .playAndRecord, mode: .voiceChat,
                        options: [.defaultToSpeaker, .duckOthers]
                    )
                #else
                    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers])
                #endif
                try session.setActive(true)
            } catch {
                voiceLog.error(
                    "voice audio session activation failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }.value
    }

    private nonisolated static func deactivateVoiceAudioSession() async {
        await Task.detached(priority: .utility) {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                // Non-fatal: iOS deactivation routinely errors while audio IO drains.
                voiceLog.notice(
                    "voice audio session deactivation: \(error.localizedDescription, privacy: .public)"
                )
            }
        }.value
    }

    // MARK: - Interruptions (AudioInterruptionPolicy's app-side half)

    private func installAudioSessionObservers() {
        removeAudioSessionObservers()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let handle: @Sendable (AudioInterruptionPolicy.Event, String) -> Void = { [weak self] event, note in
            Task { @MainActor [weak self] in
                self?.applyAudioSessionEvent(event, note: note)
            }
        }
        audioSessionObservers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { notification in
                guard let event = Self.interruptionEvent(from: notification.userInfo) else { return }
                handle(event, "Paused for the call — tap the face to carry on.")
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
            ) { notification in
                handle(
                    Self.routeChangeEvent(from: notification.userInfo),
                    "Paused — headphones came out. Tap the face to carry on."
                )
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
            ) { _ in
                handle(.mediaServicesReset, "")
            },
        ]
    }

    private func removeAudioSessionObservers() {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        audioSessionObservers.removeAll()
    }

    private func applyAudioSessionEvent(_ event: AudioInterruptionPolicy.Event, note: String) {
        guard let voiceLoop else { return }
        switch AudioInterruptionPolicy.action(for: event, in: voiceLoop.state) {
        case .none:
            break
        case .pause:
            Self.voiceLog.notice("voice mode paused: \(String(describing: event), privacy: .public)")
            voiceLoop.pause()
            avatar.resetToIdle()
            // As defensive as exit: a stop before the utterance started yields
            // no didCancel on some OS builds, so onSpeakingEnded's clear() may
            // never run — and the stale sentence would be "retired" as a bubble
            // when the next real utterance begins (review, 2026-09-03).
            speechHighlight.clear()
            voicePauseNote = note
        case .exit:
            Self.voiceLog.notice("voice mode exited: media services reset")
            exitVoiceMode()
        }
    }

    private nonisolated static func interruptionEvent(
        from userInfo: [AnyHashable: Any]?
    ) -> AudioInterruptionPolicy.Event? {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return nil }
        switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            let optionsRaw = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    private nonisolated static func routeChangeEvent(
        from userInfo: [AnyHashable: Any]?
    ) -> AudioInterruptionPolicy.Event {
        let raw = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        switch AVAudioSession.RouteChangeReason(rawValue: raw) {
        case .oldDeviceUnavailable: return .routeChanged(reason: .oldDeviceUnavailable)
        case .newDeviceAvailable: return .routeChanged(reason: .newDeviceAvailable)
        default: return .routeChanged(reason: .other)
        }
    }
}
