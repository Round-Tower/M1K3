//
//  SettingsCommands.swift
//  M1K3App
//
//  M1K3 ▸ Settings… (⌘,) — replaces the system's Settings-scene item now that
//  Settings is a screen in the main window. Summons the window (it may be
//  closed: M1K3 lives in the menu bar) and asks it for the Settings
//  destination through the same request channel the menu bar and the
//  Heartbeat link use (`pendingSidebarRequest`, consumed by ContentView).
//
//  Signed: Kev + claude-opus-5-5, 2026-09-23, Confidence 0.8 (thin glue;
//  verify-by-launch: ⌘, with the window closed, open, and minimised).
//  Prior: Unknown
//

import AppKit
import SwiftUI

struct SettingsCommands: Commands {
    let env: AppEnvironment?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                SettingsRoute.open(env: env, openWindow: openWindow)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// The one way into the Settings screen from outside the main window's own
/// sidebar: request the destination, then bring the window forward.
@MainActor
enum SettingsRoute {
    static func open(env: AppEnvironment?, openWindow: OpenWindowAction) {
        env?.pendingSidebarRequest = .settings
        openWindow(id: M1K3App.mainWindowID)
        NSApp.activate()
    }
}
