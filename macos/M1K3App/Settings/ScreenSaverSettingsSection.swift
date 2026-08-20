//
//  ScreenSaverSettingsSection.swift
//  M1K3App
//
//  The "Set Up Screen Saver" row in Settings ▸ General. M1K3 as a living
//  presence at rest — the pixel-rain and the mark, keeping watch while your Mac
//  is idle. Sits next to launch-at-login because it's the same kind of thing: a
//  one-tap system integration.
//
//  M1K3 is sandboxed, so it can't drop a bundle into ~/Library/Screen Savers
//  itself. Instead the app EMBEDS M1K3.saver (project.yml copyFiles → Resources)
//  and hands it to macOS via NSWorkspace.open — which shows the system's own
//  "Install screen saver?" prompt. That's the only sandbox-clean path, and it's
//  the same flow double-clicking a .saver in Finder triggers. The pure status /
//  path / copy is ScreenSaverInstall (M1K3ScreensaverCore, TDD'd).
//
//  Signed: Kev + claude-opus-4-8, 2026-08-20, Confidence 0.8 (the install helper
//  is TDD'd; the NSWorkspace prompt + the installed-state refresh are
//  verify-by-launch — a sandbox can't be exercised in a unit test). Prior: the
//  screensaver (PR #143).
//

import AppKit
import M1K3ScreensaverCore
import SwiftUI

struct ScreenSaverSettingsSection: View {
    @State private var installed = ScreenSaverInstall
        .isInstalled(home: FileManager.default.homeDirectoryForCurrentUser)

    var body: some View {
        Section {
            Button(ScreenSaverInstall.actionTitle(installed: installed)) { setUp() }
            if installed {
                Button("Open Screen Saver Settings") { openScreenSaverSettings() }
            }
        } header: {
            Text("Screen Saver")
        } footer: {
            Text(footerText)
        }
        .onAppear(perform: refresh)
    }

    private var footerText: String {
        ScreenSaverInstall.statusText(installed: installed)
            + " When your Mac is idle, M1K3 keeps watch — the pixel rain and the mark, drifting."
    }

    /// The embedded .saver (copied into Contents/Resources by the build).
    private func bundledSaverURL() -> URL? {
        Bundle.main.url(forResource: "M1K3", withExtension: "saver")
    }

    private func setUp() {
        guard let url = bundledSaverURL() else {
            // Nothing to install (unbundled dev build) — send them to the pane so
            // an already-installed copy can still be selected.
            openScreenSaverSettings()
            return
        }
        // macOS shows its native "Install screen saver?" sheet and, on accept,
        // copies it to ~/Library/Screen Savers and opens Screen Saver settings.
        NSWorkspace.shared.open(url)
        // The prompt is async; re-check shortly so the row updates without a
        // Settings reopen. Best-effort — a decline just leaves it unchanged.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            refresh()
        }
    }

    private func openScreenSaverSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refresh() {
        installed = ScreenSaverInstall.isInstalled(home: FileManager.default.homeDirectoryForCurrentUser)
    }
}
