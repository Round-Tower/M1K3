//
//  DialUpMuteButton.swift
//  M1K3App
//
//  An inline mute for the dial-up "connecting…" loop, shown ON the loading
//  views themselves — so when the modem screech gets annoying you can silence
//  it right there, without hunting through Settings. It toggles the SAME
//  `dialUpSound` preference the Settings switch owns (one source of truth), and
//  acts on the in-flight loop immediately: mute stops it, unmute resumes it for
//  the current load. Hidden when sound effects are off entirely — nothing to mute.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-20, Confidence 0.82 (verify-owed =
//  on-device: tap it mid-download and hear the loop stop/resume).

import M1K3Avatar
import SwiftUI

struct DialUpMuteButton: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(AppEnvironment.soundEffectsEnabledKey) private var soundEffectsEnabled = true
    @AppStorage(AppEnvironment.dialUpSoundEnabledKey) private var dialUpSound = true

    var body: some View {
        // Only meaningful while sound effects are on — otherwise the master
        // switch already silences everything and this would be a dead control.
        if soundEffectsEnabled {
            // Labelled, not icon-only (Kev, 2026-08-30): mid-download the bare
            // speaker glyph didn't read as "this stops the modem" — the words
            // are the affordance.
            Button(action: toggle) {
                Label(
                    dialUpSound ? "Mute the modem" : "Modem muted",
                    systemImage: dialUpSound ? "speaker.wave.2.fill" : "speaker.slash.fill"
                )
                .font(.caption)
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .help(dialUpSound ? "Mute the dial-up connecting sound" : "Unmute the dial-up connecting sound")
            .accessibilityLabel(dialUpSound ? "Mute dial-up sound" : "Unmute dial-up sound")
            .padding(.top, 6)
        }
    }

    private func toggle() {
        dialUpSound.toggle()
        // Act on the loop that's playing right now (this button only shows on a
        // live loading view): mute silences it at once, unmute brings it back.
        if dialUpSound {
            env.soundEffects.startLoop(.dialup)
        } else {
            env.soundEffects.stopLoop(.dialup)
        }
    }
}
