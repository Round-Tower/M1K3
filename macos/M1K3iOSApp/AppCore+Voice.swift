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
//    before the mic engine starts; activated on entry, released on exit.
//  • Endpointing came from `EndpointCadence.conversational` as of 2026-08-11 —
//    shared with the Mac. This file used to carry its own gentler pair (2.0/3.5)
//    while the Mac carried 2.0/4.5, both written for the SAME complaint ("it
//    closes before the thought is done"), which is how a tuning fix could land on
//    one surface and leave the other clipping you.
//  • Whole-answer turns for v1 — Mini/Lil answer fast on mobile; the Mac's
//    sentence-streaming poller is a named follow-up, not wired here yet.
//
//  Signed: Kev + claude-fable-5, 2026-07-29, Confidence 0.75 (adapter glue over
//  the test-pinned loop/endpointer/providers; AVAudioSession behaviour, TCC
//  dialogs, and the full spoken beat are verify-by-launch on a real device —
//  the simulator has no usable mic path for this). Prior: none (new file,
//  patterned on M1K3App/AppEnvironment+VoiceMode.swift).
//

import AVFoundation
import Foundation
import M1K3Avatar
import M1K3Voice
import os

extension AppCore {
    private static let voiceLog = Logger(subsystem: "app.m1k3", category: "stt")

    var isVoiceModeActive: Bool {
        voiceLoop != nil
    }

    /// One-time wiring (from init): speech lifecycle drives the avatar's speaking
    /// state and closes the voice loop's speak step (speechDidEnd). Outside voice
    /// mode the end callback just settles the avatar back to idle.
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
                if let voiceLoop {
                    // The loop owns the next state (auto-relisten) — no idle flash.
                    voiceLoop.speechDidEnd()
                } else {
                    avatar.resetToIdle()
                }
            }
        }
    }

    /// Enter voice-first mode and start listening. Refuses while a typed turn is
    /// streaming or the brain isn't ready. Permission dialogs (mic + speech) fire
    /// naturally on the first listen; a denied grant drains the listen empty and
    /// the loop parks idle rather than looping silently.
    func enterVoiceMode() {
        guard voiceLoop == nil, !chat.isResponding, isReady else { return }
        activateVoiceAudioSession()
        // The responder's @Sendable budget closure cannot see `voiceLoop`, so
        // the mode announces itself through the shared defaults slot — the same
        // one the Mac shell has written since voice-first shipped.
        UserDefaults.standard.set(true, forKey: VoiceModeDefaults.activeKey)
        let controller = VoiceLoopController(
            dependencies: makeVoiceLoopDependencies(),
            cadence: .conversational
        )
        voiceLoop = controller
        controller.begin()
    }

    /// Leave the mode: tears down mic + speech. An in-flight turn is NOT
    /// cancelled — its answer still lands in the chat transcript, unspoken.
    func exitVoiceMode() {
        guard let controller = voiceLoop else { return }
        controller.exit()
        voiceLoop = nil
        UserDefaults.standard.set(false, forKey: VoiceModeDefaults.activeKey)
        avatar.resetToIdle()
        deactivateVoiceAudioSession()
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
                let stream = try transcriber.startListening(finality: .keepsListening)
                avatar.setActivity(.listening)
                return stream
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
                await speech.speak(polished.isEmpty ? answer : polished)
            },
            stopSpeaking: { [weak self] in
                await self?.speech.stop()
            }
        )
    }

    // MARK: - Audio session (mobile-only ground)

    /// iOS/visionOS need an explicit record-capable session before AVAudioEngine
    /// can tap the mic. `.voiceChat` mode brings echo cancellation — M1K3 speaks
    /// out of the same device it listens on, and the loop's echoGrace alone
    /// can't unhear a speakerphone.
    private func activateVoiceAudioSession() {
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
            Self.voiceLog.error(
                "voice audio session activation failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func deactivateVoiceAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Non-fatal: iOS deactivation routinely errors while audio IO drains.
            Self.voiceLog.notice(
                "voice audio session deactivation: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
