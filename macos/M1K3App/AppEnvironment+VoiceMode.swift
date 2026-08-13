//
//  AppEnvironment+VoiceMode.swift
//  M1K3
//
//  Voice-first mode's adapter: builds the VoiceLoopController against the
//  app's existing seams. `runTurn` wraps `chat.send` DIRECTLY (not env.send —
//  its idle-reset would fight the loop's avatar ownership) and reads the
//  answer off `chat.messages.last`. The mic closure caches the provider
//  instance it started (mirroring `dictationProvider`) so stop hits the same
//  engine. While the mode is active, the in-mode brain toggle replaces the
//  global Reasoning setting entirely — off (default) forces fast even over an
//  explicit Always, on yields auto (see VoiceThinkingPolicy).
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.8 (adapter glue over
//  test-pinned loop + seams; verify-at-⌘R for the full beat). Prior: Unknown.
//  Review: claude-fable-5, 2026-07-28 — companion/shading/constellation keys
//  aliased through CompanionDefaults (M1K3Avatar) so the Mac and iOS shells
//  read the same UserDefaults slots (same string values — no migration).
//

import AppKit
import AVFoundation
import Foundation
import M1K3Avatar
import M1K3Chat
import M1K3Inference
import M1K3Voice
import os
import Speech

extension AppEnvironment {
    /// Which recogniser served a listen, and whether it could keep the room out of
    /// the mic — `stt` is the registered category for that (see M1K3LogCore).
    private nonisolated static let voiceLog = Logger(subsystem: "app.m1k3", category: "stt")

    /// Transient flag consulted by thinkingModeProvider (voice mode swaps the
    /// global Reasoning setting for the in-mode thinking toggle) and by the
    /// grounding budget (a spoken turn is trimmed for time-to-first-audio).
    /// The literal now lives in the package so the iOS shell reads the SAME
    /// slot — same string, no migration.
    nonisolated static let voiceModeActiveKey = VoiceModeDefaults.activeKey

    /// Flipped on the first successful voice-mode entry — the toolbar button
    /// stays LABELED until then (discoverability for the headline feature).
    nonisolated static let hasEnteredVoiceModeKey = "voiceMode.hasEntered"

    /// M1K3 Voice earned-moment counters (VoiceUpgradeOfferPolicy's inputs):
    /// completed spoken exchanges on the built-in voice, offers dismissed, and
    /// exchanges since the last dismissal (the re-offer currency).
    nonisolated static let voiceUpgradeExchangesKey = "voiceUpgrade.exchanges"
    nonisolated static let voiceUpgradeDismissalsKey = "voiceUpgrade.dismissals"
    nonisolated static let voiceUpgradeSinceDismissalKey = "voiceUpgrade.exchangesSinceDismissal"

    /// Voice-first mode prefers a recogniser we can put echo cancellation and
    /// other-audio ducking on (Apple Speech) over the sharper one we can't
    /// (WhisperKit builds its own audio engine inside the package). Default ON.
    ///
    /// Kev, 2026-08-11: with music playing, M1K3 and the music "both compete as
    /// opposed to ducking", and the mic hears the room — so a hands-free
    /// conversation over speakers is the wrong place to spend the last points of
    /// word accuracy. Off restores the sharper-engine-always behaviour; chat
    /// dictation is unaffected either way (it never sets the preference).
    nonisolated static let voiceEchoCancellationKey = "voiceMode.preferEchoCancellation"

    /// Live read of the echo-cancellation preference (absent key = ON).
    var prefersEchoCancellingRecogniser: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: Self.voiceEchoCancellationKey) == nil
            || defaults.bool(forKey: Self.voiceEchoCancellationKey)
    }

    /// Persisted voice-mode thinking toggle (default off = fast replies).
    /// While voice mode is active this REPLACES the Settings Reasoning picker
    /// (see VoiceThinkingPolicy). The VoiceDock's brain button writes it.
    nonisolated static let voiceModeThinkingKey = "voiceMode.thinking"

    /// Persisted voice-mode avatar choice. Empty string (default) = the pixel face;
    /// otherwise a CompanionSpec id (e.g. "Fox"). The picker writes it; the VoiceDock
    /// (via AvatarSurface) reads it. The pixel face stays M1K3's default everywhere else.
    /// The string lives in `CompanionDefaults` (M1K3Avatar) so the shared
    /// CompanionAvatarView + the iOS AppCore read the same slot — same value as before.
    nonisolated static let voiceCompanionKey = CompanionDefaults.companionKey

    /// Sentinel `voiceCompanion` value selecting the live 3D memory constellation
    /// as the companion (not a CompanionSpec id — it's procedural, not a USDZ
    /// creature). Distinct from "" (pixel face) and any spec id.
    nonisolated static let voiceCompanionConstellation = CompanionDefaults.constellationID

    /// Shading style for 3D creature companions (off / phosphor / cel). Stores a
    /// `CompanionShadingStyle` rawValue. One source of truth shared by
    /// CompanionAvatarView (applies it) and Settings (picks it) — default off.
    nonisolated static let companionShadingKey = CompanionDefaults.shadingStyleKey

    /// UI earcons (error / memory-saved / voice-mode-enter) — ON by default,
    /// switchable in Settings. Absent key reads as enabled.
    static let soundEffectsEnabledKey = "soundEffects.enabled"

    /// The persisted earcon preference (absent key = ON). Drives the lazy
    /// `soundEffects` player's initial enabled state.
    static var soundEffectsEnabledDefault: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: soundEffectsEnabledKey) == nil
            || defaults.bool(forKey: soundEffectsEnabledKey)
    }

    /// The dial-up "connecting…" loop (played while a brain downloads/loads) —
    /// ON by default, but SEPARATELY switchable. It's the one earcon that can
    /// grate (a sustained ~29s loop, not a blip), so it earns its own opt-out.
    /// Nested under the master `soundEffects` gate: BOTH must be on to play.
    static let dialUpSoundEnabledKey = "soundEffects.dialUp"

    /// Live read of the dial-up preference (absent key = ON). Read at the load
    /// call site to decide whether to start the loop.
    var dialUpSoundEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: Self.dialUpSoundEnabledKey) == nil
            || defaults.bool(forKey: Self.dialUpSoundEnabledKey)
    }

    /// One-time wiring (from init): speech lifecycle drives the avatar's speaking
    /// state, and the word-timing callbacks feed the karaoke highlight. Lives here
    /// (with speak/stopSpeaking) so the swap façade re-applies everything onto
    /// whichever tier is active and AppEnvironment.swift stays under its ceilings.
    func wireSpeechCallbacks() {
        speech.onSpeakingStarted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                avatar.setActivity(.speaking)
                // The only point that knows when sound actually reached the
                // user — the number the voice latency line is built around.
                voiceLoop?.speechDidStart()
            }
        }
        speech.onSpeakingEnded = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                speechHighlight.clear()
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

    /// Speak text via the TTS provider. The onSpeakingStarted/Ended delegate
    /// callbacks drive avatar .speaking → .idle; no manual state change needed here.
    ///
    /// Text is sanitized for speech (URLs → hosts, citation tokens and the
    /// Web-sources block dropped) BEFORE the providers see it, so every
    /// downstream word timeline is built against the same string the karaoke
    /// view displays.
    func speak(_ text: String) async {
        let polished = SpeechTextPolish.polish(text)
        // A message that is ONLY a sources block polishes to empty; never hand
        // providers "" — the voice loop waits on a speechDidEnd that would
        // not arrive.
        let spoken = polished.isEmpty ? text : polished
        speechHighlight.beginUtterance(text: spoken)
        await speech.speak(spoken)
    }

    func stopSpeaking() async {
        await speech.stop()
        avatar.resetToIdle()
        speechHighlight.clear()
    }

    /// Launch-time hygiene (from init): voice mode is never restored across
    /// launches, so a stale `true` here — a crash/force-quit while the mode was
    /// active — would silently force fast-mode thinking on every normal chat
    /// turn until the user happened to enter and leave voice mode again.
    nonisolated static func resetVoiceModeFlagAtLaunch() {
        VoiceModeDefaults.resetAtLaunch()
    }

    var isVoiceModeActive: Bool {
        voiceLoop != nil
    }

    /// The live TCC grants, in the policy's platform-neutral terms. Synchronous
    /// reads — no prompt is triggered by reading a status.
    nonisolated static func currentVoiceAuthStates()
        -> (speech: VoicePermissionPolicy.AuthState, mic: VoicePermissionPolicy.AuthState)
    {
        let speech: VoicePermissionPolicy.AuthState = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
        let mic: VoicePermissionPolicy.AuthState = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
        return (speech, mic)
    }

    /// Pre-flight for any voice gesture: a known-denied grant gets the recovery
    /// banner immediately instead of a silent empty listen. `.notDetermined`
    /// passes through — the system dialog fires naturally mid-gesture.
    func voicePermissionPreflight() -> Bool {
        let auth = Self.currentVoiceAuthStates()
        if let recovery = VoicePermissionPolicy.preflightRecovery(speechAuth: auth.speech, micAuth: auth.mic) {
            voicePermissionRecovery = recovery
            return false
        }
        return true
    }

    /// Open the exact System Settings pane the recovery names.
    func openVoicePermissionSettings() {
        guard let recovery = voicePermissionRecovery,
              let url = URL(string: recovery.settingsPaneURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Enter voice-first mode and start listening. Refuses while a typed turn
    /// is streaming or chat-mode dictation is live (the toolbar button is
    /// disabled in both states — this guard is the belt to that suspender).
    func enterVoiceMode() {
        guard voiceLoop == nil, !chat.isResponding, !isListening else { return }
        guard voicePermissionPreflight() else { return }
        // The loop owns speech from here; a chat auto-speak session mid-answer
        // would talk over it (its poll-tick guard also bails, but the in-flight
        // utterance needs the explicit stop).
        cancelAutoSpeak()
        UserDefaults.standard.set(true, forKey: Self.hasEnteredVoiceModeKey)
        UserDefaults.standard.set(true, forKey: Self.voiceModeActiveKey)
        soundEffects.play(.voiceEnter) // M1K3 materialising
        // Conversational endpointing lives in EndpointCadence now — ONE preset,
        // shared with the iOS shell, which used to carry its own drifted copy of
        // these numbers from the same complaint. The endpointer also learns Kev's
        // own pause rhythm on top of the preset (2026-08-11), so these values only
        // have to be right for the first pause of a session.
        let controller = VoiceLoopController(
            dependencies: makeVoiceLoopDependencies(),
            cadence: .conversational
        )
        voiceLoop = controller
        controller.begin()
        // Voice deserves the sharper engine — UNLESS we've chosen a clean duplex
        // channel over raw accuracy for this mode, in which case pulling a
        // WhisperKit model down is work whose result we'd then decline to use.
        // NON-blocking either way: the loop re-resolves its provider at the start
        // of EACH listen, so it upgrades on the next cycle once ready.
        if !isWhisperKitActive, !prefersEchoCancellingRecogniser {
            Task { [weak self] in await self?.enableWhisperKit() }
        }
    }

    /// Leave the mode: tears down mic + speech. An in-flight turn is NOT
    /// cancelled — its answer still lands in the chat transcript, unspoken.
    func exitVoiceMode() {
        guard let controller = voiceLoop else { return }
        controller.exit()
        voiceLoop = nil
        UserDefaults.standard.set(false, forKey: Self.voiceModeActiveKey)
        avatar.resetToIdle()
        speechHighlight.clear()
        // An exit mid-turn evaluates on a tally that misses that turn's
        // exchange (recordSpokenExchange fires when the answer lands) — the
        // exchange banks for the NEXT exit. Deliberate: an undercount can
        // only delay the offer, never mis-fire it.
        evaluateVoiceUpgradeOffer()
    }

    // MARK: - M1K3 Voice earned moment

    /// A completed spoken exchange on the BUILT-IN voice — the currency that
    /// earns the M1K3 Voice offer. Called from the loop's successful turns.
    func recordSpokenExchange() {
        guard selectedVoiceTier == .builtin else { return }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: Self.voiceUpgradeExchangesKey) + 1,
                     forKey: Self.voiceUpgradeExchangesKey)
        defaults.set(defaults.integer(forKey: Self.voiceUpgradeSinceDismissalKey) + 1,
                     forKey: Self.voiceUpgradeSinceDismissalKey)
    }

    /// On leaving voice mode: the honest pitch moment — the user has just
    /// HEARD the everyday voice in real conversation. Never mid-session.
    private func evaluateVoiceUpgradeOffer() {
        let defaults = UserDefaults.standard
        voiceUpgradeOffered = VoiceUpgradeOfferPolicy.shouldOffer(
            spokenExchanges: defaults.integer(forKey: Self.voiceUpgradeExchangesKey),
            m1k3VoiceActiveOrStaged: selectedVoiceTier == .m1k3Voice || voiceLoad.isActive,
            dismissals: defaults.integer(forKey: Self.voiceUpgradeDismissalsKey),
            exchangesSinceLastDismissal: defaults.integer(forKey: Self.voiceUpgradeSinceDismissalKey)
        )
    }

    /// "Get M1K3 Voice" — rides the existing prepareM1K3Voice path (voiceLoad
    /// drives Settings' progress; the speech façade swaps when ready). The
    /// toast goes through showBrainUpgradeNotice for its auto-clear — a
    /// directly-set notice would mask the ingest banner forever.
    func acceptVoiceUpgrade() {
        voiceUpgradeOffered = false
        showBrainUpgradeNotice("Fetching my proper voice — I'll switch over when it's ready.")
        Task { [weak self] in await self?.prepareM1K3Voice() }
    }

    func dismissVoiceUpgrade() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: Self.voiceUpgradeDismissalsKey) + 1,
                     forKey: Self.voiceUpgradeDismissalsKey)
        defaults.set(0, forKey: Self.voiceUpgradeSinceDismissalKey)
        voiceUpgradeOffered = false
    }

    private func makeVoiceLoopDependencies() -> VoiceLoopController.Dependencies {
        // Cache the recogniser each listen started, so stop hits that engine
        // even if the router's preference changes mid-session.
        var activeProvider: (any TranscriptionProvider)?
        return VoiceLoopController.Dependencies(
            startListening: { [weak self] in
                // Strong-bind up front: nested @Sendable closures below may not
                // reference a weak (mutable) capture under strict concurrency,
                // and holding the app-lifetime environment for a listen is fine.
                guard let self,
                      let provider = transcription.activeProvider(
                          preferringEchoCancellation: prefersEchoCancellingRecogniser
                      )
                else {
                    throw VoiceTurnFailure(message: "No speech recogniser is available.")
                }
                let stream = try provider.startListening()
                activeProvider = provider
                // Which engine served, and whether it can keep the room out of the
                // mic, is the first question when someone reports M1K3 talking over
                // the music or answering something they didn't say.
                Self.voiceLog.notice(
                    "voice listening on \(provider.name, privacy: .public) (echo cancellation attempted: \(provider.attemptsEchoCancellation, privacy: .public))"
                )
                // Zero-segment backstop (the silent-denial fix's second layer):
                // a listen that drains with NO segments while a grant reads
                // blocked means the user hit notDetermined→deny mid-gesture or
                // revoked mid-session. Voice mode can't work at all then — exit
                // it and raise the recovery banner instead of looping silently.
                return AsyncStream { continuation in
                    let forwarder = Task {
                        var sawSegments = false
                        for await segment in stream {
                            sawSegments = true
                            continuation.yield(segment)
                        }
                        continuation.finish()
                        // finish() fires onTermination → forwarder.cancel() on
                        // THIS task — safe because there's deliberately no
                        // cancellation checkpoint between here and the backstop
                        // below. Adding Task.checkCancellation() here would
                        // silently disable the silent-denial backstop.
                        let auth = Self.currentVoiceAuthStates()
                        if let recovery = VoicePermissionPolicy.backstopRecovery(
                            speechAuth: auth.speech, micAuth: auth.mic, sawSegments: sawSegments
                        ) {
                            Task { @MainActor in
                                self.voicePermissionRecovery = recovery
                                self.exitVoiceMode()
                            }
                        }
                    }
                    continuation.onTermination = { _ in forwarder.cancel() }
                }
            },
            stopListening: {
                activeProvider?.stopListening()
                activeProvider = nil
            },
            runTurn: { [weak self] question in
                guard let self else {
                    return .failure(VoiceTurnFailure(message: "M1K3 is shutting down."))
                }
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
                recordSpokenExchange()
                return .success(last.text)
            },
            speak: { [weak self] answer in
                await self?.speak(answer)
            },
            stopSpeaking: { [weak self] in
                // The highlight clears via wireSpeechCallbacks' onSpeakingEnded
                // (stop() guarantees exactly one); exitVoiceMode covers the
                // not-speaking case. No clear needed here.
                await self?.speech.stop()
            },
            // Sentence-streamed speech (2026-07-25): watch the assistant
            // message WHILE chat.send streams into it and fold complete
            // sentences out (SentenceStreamFolder) — first audio arrives at
            // the first sentence, not after the whole ~25s Big generation.
            // Poll-based on purpose: ChatSession already streams into the
            // @Observable message; a 150ms cadence is far below speech
            // latency and needs no new seams in the TDD'd chat machinery.
            runTurnStreaming: { [weak self] question, onChunk in
                guard let self else {
                    return .failure(VoiceTurnFailure(message: "M1K3 is shutting down."))
                }
                var folder = SentenceStreamFolder(stopMarker: FollowUpSplit.sentinel)
                var emitted = false
                var streamedText = ""
                // Pin to THIS turn's assistant message by id — never read
                // `messages.last`. A delegate_deep delivery (or any out-of-band
                // append) lands as a NEW last message; folding THAT as the
                // voice answer would speak the deep-dive instead (2026-07-25
                // review finding). `send` appends [user, assistant] at the
                // baseline, so the assistant is the first assistant at/after
                // baselineCount; capture its id once it exists.
                let baselineCount = chat.messages.count
                var pinnedID: UUID?
                /// Fold only forward-growing text: if the pinned message's text
                /// stops being a prefix-extension (FOLLOWUPS split / polish
                /// rewrite shrinks it), skip — the folder's divergence reset
                /// would otherwise re-speak the whole answer. Same guard the
                /// final fold uses, applied to every poll (2026-07-25 finding).
                @MainActor func foldForward(_ text: String) {
                    guard text.hasPrefix(streamedText) else { return }
                    for sentence in folder.ingest(text) {
                        emitted = true
                        onChunk(sentence)
                    }
                    streamedText = text
                }
                @MainActor func pinnedMessage() -> ChatMessage? {
                    if let pinnedID { return chat.messages.first { $0.id == pinnedID } }
                    guard chat.messages.count > baselineCount else { return nil }
                    let candidate = chat.messages[baselineCount...].first { $0.role == .assistant }
                    pinnedID = candidate?.id
                    return candidate
                }
                let poller = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard self != nil, let message = pinnedMessage() else { continue }
                        foldForward(message.text)
                    }
                }
                await chat.send(question)
                poller.cancel()
                guard let settled = pinnedMessage() else {
                    return .failure(VoiceTurnFailure(message: "No answer arrived."))
                }
                if case let .failed(message) = settled.status {
                    // Chunks may already have spoken; the loop drains them and
                    // re-listens (machine-pinned) while the error surfaces.
                    return .failure(VoiceTurnFailure(message: message))
                }
                foldForward(settled.text)
                if let tail = folder.flush() {
                    emitted = true
                    onChunk(tail)
                }
                guard emitted else {
                    return .failure(VoiceTurnFailure(message: "The model had nothing to say."))
                }
                recordSpokenExchange()
                return .success(())
            }
        )
    }
}
