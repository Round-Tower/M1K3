//
//  GeneralSettingsPane.swift
//  M1K3App
//
//  The "General" Settings tab: startup + Dock behaviour, notifications, sound
//  effects. Split out of the old single-Form SettingsView (2026-07-13) — see
//  SettingsView.swift for the shell. One Kev-approved cut landed here: the
//  menu-bar glyph picker is gone — the pixel M ships as THE glyph
//  (M1K3App.swift), not a choice (see MenuBarGlyph.swift). Voice mode
//  (echo cancellation) and Reasoning moved to the M1K3 tab (2026-09-01 IA
//  pass) — they're brain/voice behaviour, not app chrome; General now covers
//  ONLY things about the app itself, never M1K3's mind.
//
//  Signed: Kev + claude-fable-5, 2026-07-13, Confidence 0.85 (a straight move
//  of Startup/Notifications/Sound/Reasoning, minus the glyph picker). Prior:
//  Kev + claude-opus-4-8 (SettingsView.swift lineage, 2026-06-06).
//

import AppKit
import M1K3Launch
import SwiftUI

struct GeneralSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @AppStorage(AppEnvironment.notifyOnLongTurnKey) private var notifyOnLongTurn = false
    @AppStorage(AppEnvironment.soundEffectsEnabledKey) private var soundEffectsEnabled = true
    @AppStorage(AppEnvironment.dialUpSoundEnabledKey) private var dialUpSound = true
    @AppStorage(AppEnvironment.notchHUDEnabledKey) private var notchHUDEnabled = false
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
                Text("Pings you when a long reply finishes or a brain loads — only "
                    + "while M1K3's in the background, never with the reply itself.")
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
                Text("Short earcons for errors, saved memories, and voice mode waking "
                    + "up — never over M1K3's voice. The dial-up sound plays while a "
                    + "brain loads and has its own switch since it loops.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show a heads-up display while M1K3 talks", isOn: $notchHUDEnabled)
            } header: {
                Text("Narration HUD")
            } footer: {
                Text("A small pill under your menu bar shows your companion and what "
                    + "M1K3 is saying — even with the window closed. Off by default.")
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
            Text("\u{201C}Menu bar only\u{201D} hides the Dock icon and starts M1K3 quietly "
                + "— open it anytime from the menu bar.")
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
