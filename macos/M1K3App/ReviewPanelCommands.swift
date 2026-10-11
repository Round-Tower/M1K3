//
//  ReviewPanelCommands.swift
//  M1K3App
//
//  View ▸ Toggle Review Panel (⌥⌘R). The toolbar toggle is the window's rightmost item,
//  so on a narrow window it is the first to spill into ">>" (#78); the menu item owns the
//  shortcut and keeps the panel reachable either way. Same shape as SettingsCommands.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.75 (thin glue; verify-by-launch:
//  ⌥⌘R with the window narrow, and the title flipping Show/Hide). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (review fold) — one stable "Toggle Review Panel" title;
//  a Show/Hide flip read state inside a Commands body, where observation is unproven. Confidence 0.85.
//

import SwiftUI

struct ReviewPanelCommands: Commands {
    let env: AppEnvironment?

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            // A stable title: observation inside a Commands body is unproven here, and a title
            // that never refreshed would say Show while the panel is open. The toolbar button
            // carries the state.
            Button(String(localized: "Toggle Review Panel")) {
                env?.review.isPresented.toggle()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(env == nil)
        }
    }
}
