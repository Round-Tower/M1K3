//
//  VoiceOutputSection.swift
//  M1K3iOS / M1K3visionOS
//
//  The Voice section of Settings — how M1K3 sounds. Two tiers, same rows as the
//  Brain picker: Built-in (instant, no download — the default) and M1K3 Voice
//  (Kokoro, one ~192 MB download, then offline forever). Picking M1K3 Voice IS the
//  download consent; the bar below the rows is the honest progress; "Hear a
//  sample" speaks in whichever voice is live right now.
//
//  On the Simulator only Built-in is offered — M1K3 Voice is MLX, which aborts
//  there (AppCore.neuralVoiceAvailable).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-03, Confidence 0.8 (composition over
//  AppCore+VoiceOutput; the rows are the Brain picker's idiom byte-for-byte; the
//  download bar and the sample are verify-by-launch on device).
//  Prior: none (new file, patterned on SettingsScreen's Brain section).
//  Review: Kev + claude-opus-5-5, 2026-09-25 — the unavailable note comes from MLXRuntimeSupport.voiceNote, so an
//  A12-family GPU says why (a newer chip) instead of blaming the Simulator; ~192 MB in the header. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-12 — a "Sound effects" toggle (the Mac's key) for the iPhone's new earcons;
//  it reaches the live player at once. Verify-on-device.
//  Review: Kev + claude-opus-5.5, 2026-10-12 — "Speak answers" (chat auto-speak, the Mac's key): off stops the voice at once.
//  Review: Kev + claude-fable-5.2, 2026-11-14 — quiet text moves from `.secondary` to `.readableSecondary`
//  (ReadableSecondary.swift), as on the Mac in #831. Not yet measured on the phone at the time of writing.
//  Review: Kev + claude-opus-5.5, 2026-11-17 — the voice rows draw SettingsChoiceRow: the whole row takes the touch.
//  Review: claude-opus-5-5, 2026-11-19 — localisation: the rows show `VoiceTier.localizedName` ("Built-in" from
//  M1K3Voice's catalog; the iPhone pseudo pass showed it single). English unchanged.
//  Review: Kev + claude-opus-5.5, 2026-11-26 — "Keep talking when locked" (VoiceBehindLock.switchKey, on by default,
//  Kev): a voice conversation goes on behind the lock (iPhone only). Confidence 0.8.
//

import M1K3Inference
import M1K3Voice
import SwiftUI

struct VoiceOutputSection: View {
    @Environment(AppCore.self) private var core
    /// Earcons (the Mac's key): on unless turned off; the player reads it live.
    @AppStorage(AppCore.soundEffectsEnabledKey) private var soundEffectsEnabled = true
    /// Chat auto-speak (the Mac's key): answers read aloud as they stream, in the voice above.
    @AppStorage(VoiceModeDefaults.autoSpeakKey) private var autoSpeak = false
    /// Voice behind the lock (VoiceBehindLockPolicy): read as the app leaves, so a change applies at the next lock.
    @AppStorage(VoiceBehindLock.switchKey) private var keepsTalkingWhenLocked = VoiceBehindLockPolicy.onByDefault

    private var tiers: [VoiceTier] {
        AppCore.neuralVoiceAvailable ? VoiceTier.allCases : [.builtin]
    }

    var body: some View {
        Section {
            ForEach(tiers) { tier in
                SettingsChoiceRow(
                    glyph: tier.glyph,
                    title: tier.localizedName,
                    detail: tier.tagline,
                    isChosen: core.selectedVoiceTier == tier
                ) {
                    core.selectVoiceTier(tier)
                }
            }
            loadState
            if let note = AppCore.mlxSupport.voiceNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.readableSecondary)
            }
            Button("Hear a sample") {
                Task { await core.speakSample() }
            }
            Toggle("Speak answers", isOn: $autoSpeak)
                .onChange(of: autoSpeak) { _, on in
                    guard !on else { return }
                    core.cancelAutoSpeak()
                    Task { await core.stopSpeakingAnswer() }
                }
            Toggle("Sound effects", isOn: $soundEffectsEnabled)
                .onChange(of: soundEffectsEnabled) { _, enabled in core.soundEffects.isEnabled = enabled }
            #if os(iOS)
                Toggle(isOn: $keepsTalkingWhenLocked) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep talking when locked")
                        Text("""
                        Lock your phone mid-conversation and M1K3 keeps listening and answering out loud. Lil and Big \
                        can't run behind the lock, so your paired Mac answers, or Apple's model if there isn't one. \
                        A minute of silence ends it.
                        """)
                        .font(.caption)
                        .foregroundStyle(.readableSecondary)
                    }
                }
            #endif
        } header: {
            Text("Voice")
        } footer: {
            // The chosen tier's own card copy — the fact and the guarantee.
            Text(core.selectedVoiceTier.detail)
        }
    }

    /// Download progress while M1K3 Voice stages, the failure if it didn't —
    /// the Mac's voiceOutputControl, in Form rows.
    @ViewBuilder
    private var loadState: some View {
        switch core.voiceLoad {
        case let .downloading(fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text(core.voiceLoad.label(modelName: "M1K3 Voice"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.readableSecondary)
            }
        case .preparing:
            ProgressView()
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle, .ready:
            EmptyView()
        }
    }
}
