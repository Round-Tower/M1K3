//
//  GeneralSettingsPane.swift
//  M1K3App
//
//  The "General" Settings tab: startup + Dock behaviour, notifications, sound
//  effects, reasoning budget. Split out of the old single-Form SettingsView
//  (2026-07-13) — see SettingsView.swift for the shell. One Kev-approved cut
//  landed here: the menu-bar glyph picker is gone — the pixel M ships as THE
//  glyph (M1K3App.swift), not a choice (see MenuBarGlyph.swift).
//
//  Signed: Kev + claude-fable-5, 2026-07-13, Confidence 0.85 (a straight move
//  of Startup/Notifications/Sound/Reasoning, minus the glyph picker). Prior:
//  Kev + claude-opus-4-8 (SettingsView.swift lineage, 2026-06-06).
//

import AppKit
import M1K3Chat
import M1K3Launch
import SwiftUI

struct GeneralSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @AppStorage(AppEnvironment.notifyOnLongTurnKey) private var notifyOnLongTurn = false
    @AppStorage(AppEnvironment.soundEffectsEnabledKey) private var soundEffectsEnabled = true
    @AppStorage(AppEnvironment.dialUpSoundEnabledKey) private var dialUpSound = true
    @AppStorage(AppEnvironment.voiceEchoCancellationKey) private var preferEchoCancellation = true
    @AppStorage(AppEnvironment.thinkingModeKey) private var thinkingMode = ThinkingMode.auto.rawValue
    @AppStorage(StartupPreferences.menuBarOnlyKey) private var menuBarOnly = false
    @State private var showResetOnboarding = false

    var body: some View {
        Form {
            startupSection

            ScreenSaverSettingsSection()

            Section {
                Toggle("Notify me in the background", isOn: $notifyOnLongTurn)
                    .onChange(of: notifyOnLongTurn) { _, on in
                        Task { await env.setLongTurnNotifications(on) }
                    }
            } header: {
                Text("Notifications")
            } footer: {
                Text("When you tab away, M1K3 pings you as things finish — a long "
                    + "reply is ready, a brain finishes downloading, or a brain is "
                    + "loaded and ready. Only while the app is in the background, "
                    + "and never with the reply itself: on-device, private. Off by "
                    + "default.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Sound effects", isOn: $soundEffectsEnabled)
                    .onChange(of: soundEffectsEnabled) { _, on in
                        env.soundEffects.isEnabled = on
                    }
                Toggle("Dial-up sound while loading", isOn: $dialUpSound)
                    .onChange(of: dialUpSound) { _, on in
                        // Flipping it off mid-download kills the loop at once —
                        // the whole point is "make it stop, it's annoying".
                        if !on { env.soundEffects.stopLoop(.dialup) }
                    }
                    .disabled(!soundEffectsEnabled)
            } header: {
                Text("Sound effects")
            } footer: {
                Text("Short earcons for a few moments — an error, a memory saved, "
                    + "voice mode waking up. They never play over M1K3's voice. "
                    + "On-device only. The dial-up \u{201C}connecting\u{201D} sound plays while "
                    + "a brain downloads or loads — nostalgic, but a long loop, so "
                    + "it has its own switch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep other audio out of the mic", isOn: $preferEchoCancellation)
            } header: {
                Text("Voice mode")
            } footer: {
                Text("In voice mode M1K3 listens with the recogniser it can put echo "
                    + "cancellation on, so music ducks while you talk and M1K3 doesn't "
                    + "hear itself. Turn this off to always use the sharper transcriber "
                    + "instead \u{2014} more accurate in a quiet room, but it hears whatever "
                    + "your speakers are playing. Takes effect on your next turn.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Reasoning", selection: $thinkingMode) {
                    Text("Auto").tag(ThinkingMode.auto.rawValue)
                    Text("Always think").tag(ThinkingMode.always.rawValue)
                    Text("Fast answers").tag(ThinkingMode.fast.rawValue)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Reasoning")
            } footer: {
                // Multiline literal, not a + chain (see the web-search footer above).
                Text("""
                Reasoning models think out loud before answering — great for \
                hard questions, slow for small talk. Auto skips the thinking \
                on casual turns and keeps it for grounded or analytic ones. \
                Voice mode has its own thinking toggle (the brain button) \
                and ignores this setting while active.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Destructive re-run confirm, hoisted off the leaf Button (Startup section)
        // so it presents reliably — a confirmationDialog on a Button inside a Form
        // can silently fail to show on macOS, and this gate guards a full reset.
        .confirmationDialog(
            "Re-run the first-run setup?",
            isPresented: $showResetOnboarding,
            titleVisibility: .visible
        ) {
            Button("Re-run onboarding", role: .destructive) {
                // The one-screen hello again — NOT the brain-only re-pick.
                // Honest to the message below: a blank name won't clear the
                // saved profile, and a non-Mini brain is kept as-is.
                UserDefaults.standard.set(false, forKey: M1K3App.onboardingStartAtBrainKey)
                UserDefaults.standard.set(false, forKey: AppEnvironment.hasChosenBrainKey)
            }
        } message: {
            Text("Shows the first-run hello again. "
                + "Your saved profile, brain and downloaded models are kept.")
        }
        // Re-read the live login-item status each time Settings opens, so a grant
        // the user just made in System Settings (which we can't observe) is
        // reflected without them having to toggle it again.
        .onAppear { launchAtLogin.refresh() }
    }

    /// Launch-at-login + Dock visibility + the onboarding reset. The toggle
    /// drives the reconcile policy in LaunchAtLogin (idempotent + error-catching);
    /// requiresApproval / lastError surface inline so a blocked grant isn't silent.
    private var startupSection: some View {
        Section {
            Toggle("Launch M1K3 at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            if launchAtLogin.requiresApproval {
                Button("Approve in System Settings…") { openLoginItemsSettings() }
                    .buttonStyle(.glass)
            }
            if let error = launchAtLogin.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            // Live: flip the Dock icon now for instant feedback. The window-at-
            // launch suppression is applied by defaultLaunchBehavior next launch.
            Toggle("Show in menu bar only (hide Dock icon)", isOn: $menuBarOnly)
                .onChange(of: menuBarOnly) { _, on in
                    // Same decision gate as the AppDelegate's launch path.
                    let hidesDock = StartupVisibility(menuBarOnly: on).hidesDockIcon
                    NSApp.setActivationPolicy(hidesDock ? .accessory : .regular)
                }
            // Action only — the destructive confirm is hoisted onto the Form (see
            // `body`) so it presents reliably; a confirmationDialog on a leaf Button
            // inside a Form can silently fail to show on macOS, and this gate guards
            // a full onboarding reset.
            Button("Re-run onboarding…", role: .destructive) { showResetOnboarding = true }
                .buttonStyle(.glass)
        } header: {
            Text("Startup")
        } footer: {
            Text("Keep M1K3 in your menu bar and start it automatically when you log "
                + "in, so it's always a click away. \"Menu bar only\" hides the Dock "
                + "icon and starts M1K3 quietly (no window) — open it any time from the "
                + "menu. M1K3 stays on-device either way.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Open System Settings at Login Items. The deep-link pane id has drifted
    /// across macOS releases, so if the specific URL won't open we fall back to
    /// System Settings' root rather than leave the button silently dead.
    private func openLoginItemsSettings() {
        let deepLink = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        if let deepLink, NSWorkspace.shared.open(deepLink) { return }
        if let root = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(root)
        }
    }
}
