//
//  AppCore+VoiceOutput.swift
//  M1K3iOS / M1K3visionOS
//
//  Voice OUTPUT tier — the iOS sibling of the Mac's AppEnvironment "Voice output
//  (TTS tier)" extension. Built-in (AVSpeechSynthesizer) is the first-run default
//  and the instant swap-back; M1K3 Voice (Kokoro, pure MLX) downloads once on pick
//  and then runs fully on-device. The download is the consent: nothing fetches
//  until the user taps the tier, and launch only restores it when the weights are
//  already staged (VoiceTierRestore — never a silent ~192 MB re-download).
//
//  One deliberate difference from the Mac: the download is a HELD task. Picking
//  Built-in mid-download cancels it, so the swap can't land a minute later on top
//  of a choice the user already reversed (the Mac's inline version lets the
//  finished download win; flagged there, fixed here first).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-03, Confidence 0.8 (composition of the
//  package seams — SwappableSpeechProvider, KokoroSpeechProvider.prepare,
//  VoiceTierRestore; the download, the swap, and Kokoro rendering through the
//  phone's audio session are verify-by-launch on device — the Simulator has no
//  MLX). Prior: none (new file, patterned on AppEnvironment.swift's extension).
//  Review: Kev + claude-fable-5.1, 2026-09-03 — a failed prepare drops the row back to Built-in (the tier that is
//  actually wired), per the #199 review note; the Mac keeps the older optimistic behaviour.
//  Review: Kev + claude-fable-5.1, 2026-09-03 (post-merge folds) — the progress tick is generation-stamped, and an
//  explicit Built-in pick clears a stale failure banner.
//  Review: Kev + claude-opus-5-5, 2026-09-25 — doc only: neuralVoiceAvailable (= mlxAvailable) now also refuses an
//  A12-family GPU (warming Kokoro traps there); ~192 MB. Confidence 0.9.
//  Review: Kev + claude-opus-5-5, 2026-10-13 — `readAloud(_:)`: an answer's speaker button (MessageBubble), polished
//  for speech like the Mac's speak path, in the same playback session as the sample; refused while a voice
//  conversation holds the audio. Confidence 0.8 (verify-by-launch).
//  Review: Kev + claude-opus-5-5, 2026-10-13 (#597 follow-up) — readAloud is a toggle (a tap while speaking stops),
//  refuses while an answer streams, and re-checks voice mode after the session hop. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — `activateSampleAudioSession` is internal: chat
//  auto-speak plays under the same session instead of keeping its own copy (which swallowed errors unlogged).
//  Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — readAloud knows about chat auto-speak (master's
//  button and the branch's auto-speak met in the merge): a tap while an answer is being auto-spoken stops the whole
//  answer, where it used to skip one sentence or queue a second reading over it. Confidence 0.8 (verify on the phone).
//

import AVFoundation
import M1K3Inference
import M1K3Kokoro
import M1K3Voice
import os

extension AppCore {
    private nonisolated static let ttsLog = Logger(subsystem: "app.m1k3", category: "voice")

    /// M1K3 Voice is MLX — it cannot run on the Simulator (MLX aborts the
    /// process there) or an A12-family GPU (warming Kokoro traps — iPad 8th
    /// gen, 2026-09-25), so the picker offers only Built-in there.
    static var neuralVoiceAvailable: Bool {
        mlxAvailable
    }

    /// Switch the active TTS tier. Built-in swaps back instantly (and cancels an
    /// in-flight download); M1K3 Voice kicks the download, or swaps in at once
    /// when the weights are already staged.
    func selectVoiceTier(_ tier: VoiceTier) {
        switch tier {
        case .builtin:
            voicePrepareTask?.cancel()
            voicePrepareTask = nil
            speech.setProvider(builtinSpeech)
            selectedVoiceTier = .builtin
            UserDefaults.standard.set(VoiceTier.builtin.rawValue, forKey: Self.selectedVoiceTierKey)
            // Unconditional: an explicit Built-in pick also clears a stale
            // `.failed` banner from an earlier attempt (review note, #199).
            voiceLoad = .idle
        case .m1k3Voice:
            guard Self.neuralVoiceAvailable else { return }
            prepareM1K3Voice()
        }
    }

    /// Download + stage the Kokoro model (real progress into `voiceLoad`), then
    /// swap the speech façade to M1K3 Voice. Idempotent — one task at a time, and
    /// the provider returns instantly once the weights are on disk.
    func prepareM1K3Voice() {
        guard voicePrepareTask == nil else { return }
        voicePrepareGeneration += 1
        let generation = voicePrepareGeneration
        voiceLoad = .progress(0)
        voicePrepareTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // Only clear our own handle — a cancel-then-repick may already
                // hold a newer task here.
                if voicePrepareGeneration == generation { voicePrepareTask = nil }
            }
            do {
                try await kokoro.prepare { fraction in
                    Task { @MainActor [weak self] in
                        // Only while still downloading — the late-hop-over-.ready
                        // guard the Mac's preloadGemma/enableWhisperKit use too —
                        // and only for THIS generation: a cancelled download's
                        // last queued tick must not paint over a fresh one.
                        guard let self, voicePrepareGeneration == generation,
                              case .downloading = voiceLoad else { return }
                        voiceLoad = .progress(fraction)
                    }
                }
                // A Built-in pick landed while the bytes were still coming: it
                // already reset the state; the finished download must not win.
                guard !Task.isCancelled else { return }
                speech.setProvider(kokoro)
                selectedVoiceTier = .m1k3Voice
                UserDefaults.standard.set(VoiceTier.m1k3Voice.rawValue, forKey: Self.selectedVoiceTierKey)
                voiceLoad = .ready
            } catch is CancellationError {
                // selectVoiceTier(.builtin) owns the state on this path.
            } catch {
                guard !Task.isCancelled else { return }
                // The façade never left Built-in — say so in the row, not just
                // the banner (review note on #199; the Mac still shows the
                // chosen-but-unwired tier here).
                selectedVoiceTier = .builtin
                voiceLoad = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Read one answer aloud: the speaker button on M1K3's turns (MessageBubble).
    /// A tap while anything is being read stops it (a toggle, so Built-in's queue
    /// never reads an answer twice). Polished for speech as the Mac does. Silent
    /// while an answer streams or a voice conversation holds the audio session,
    /// checked again after the session hop. The session is released when speech
    /// ends (AppCore+Voice), so ducked music comes back.
    func readAloud(_ text: String) {
        guard !isVoiceModeActive, !chat.isResponding else { return }
        // While an answer is being auto-spoken, the button is its Stop: `speech.stop()` alone would skip only the
        // current sentence (the loop speaks the next), and between sentences a tap would queue a second reading.
        if autoSpeakTask != nil {
            cancelAutoSpeak()
            Task { await stopSpeakingAnswer() }
            return
        }
        let polished = SpeechTextPolish.polish(text)
        let spoken = polished.isEmpty ? text : polished
        Task {
            if await speech.isSpeaking() {
                await speech.stop()
                return
            }
            await Self.activateSampleAudioSession()
            guard !isVoiceModeActive, !chat.isResponding else { return }
            await speech.speak(spoken)
        }
    }

    /// Speak a short line in the CURRENT voice — Settings' "Hear a sample". The
    /// façade decides who speaks, so mid-download this is honestly Built-in.
    func speakSample() async {
        await Self.activateSampleAudioSession()
        await speech.speak(SpokenName.introduction)
    }

    /// Settings is reachable only outside voice mode, whose session is
    /// `.playAndRecord`; a plain `.playback` session here plays the sample
    /// through the speaker and past the ring/silent switch (under the default
    /// `.soloAmbient` a muted phone would "hear" nothing and read as broken).
    /// Entering voice mode re-activates its own category afterwards. Also the
    /// session a readout and an auto-spoken answer play under (one copy).
    nonisolated static func activateSampleAudioSession() async {
        await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)
            } catch {
                ttsLog.error(
                    "sample audio session activation failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }.value
    }
}
