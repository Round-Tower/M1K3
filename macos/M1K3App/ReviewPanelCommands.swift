//
//  ReviewPanelCommands.swift
//  M1K3App
//
//  View ▸ Show/Hide Review Panel (⌥⌘R). The toolbar toggle is the window's rightmost item,
//  so on a narrow window it is the first to spill into ">>" (#78); the menu item owns the
//  shortcut and keeps the panel reachable either way. Same shape as SettingsCommands.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.75 (thin glue; verify-by-launch:
//  ⌥⌘R with the window narrow, and the title flipping Show/Hide). Prior: none (new file).
//

import SwiftUI

struct ReviewPanelCommands: Commands {
    let env: AppEnvironment?

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(env?.review.isPresented == true
                ? String(localized: "Hide Review Panel")
                : String(localized: "Show Review Panel"))
            {
                env?.review.isPresented.toggle()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(env == nil)
        }
    }
}
