//
//  SharedFileInbox.swift
//  M1K3App
//
//  Open With on the Mac (1.6, #893 C, the Mac half of "share to M1K3"): Finder's Open With, a drop on the Dock
//  icon and `open -a M1K3 file.json` all reach `AppDelegate.application(_:open:)`, which hands the URLs here.
//  The inbox lives on the delegate, above the onboarding gate and outside the window, so a file that arrives at a
//  cold launch, mid-onboarding or with the window closed (menu-bar only) is held, not lost. ContentView stages
//  what it holds through the paperclip's own `attach` (`receiveSharedFiles`) and never sends it; the person reads
//  what landed and presses send. Every decision is `SharedFileIntake`'s (pure, tested); this only holds and wakes.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.8 (thin glue over SharedFileIntake; the Finder, Dock
//  and closed-window paths are launch checks). Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-11-23 (pre-push review) — `receive` says whether a file came, so a web link
//  no longer brings M1K3 forward. Confidence 0.8.
//

import AppKit
import M1K3Inference
import Observation
import SwiftUI

/// Files handed to M1K3 by Launch Services, waiting for the chat to stage them.
@MainActor
@Observable
final class SharedFileInbox {
    /// Waiting to be staged, oldest first; each file once.
    private(set) var files: [URL] = []
    /// Bumped on every arrival that carried a file, so the status-bar label can summon the main window even when
    /// the file was already held (a second Open With still brings M1K3 forward).
    private(set) var arrivals = 0

    /// Whether the arrival carried a file (the delegate brings the app forward only then).
    @discardableResult
    func receive(_ urls: [URL]) -> Bool {
        // Nothing to stage (a web URL, an m1k3:// link the Mac doesn't register): nothing held, nothing summoned.
        guard !SharedFileIntake.admit(urls, holding: []).isEmpty else { return false }
        files = SharedFileIntake.admit(urls, holding: files)
        arrivals += 1
        return true
    }

    /// Everything waiting, handed over once: the inbox is empty after.
    func take() -> [URL] {
        let waiting = files
        files = []
        return waiting
    }
}

/// Brings the main window forward when a file arrives. It rides the menu-bar label, the one view mounted for the
/// app's whole life, because the main `Window` may be closed (menu-bar only) and a closed window can't open itself.
struct SharedFileSummons: ViewModifier {
    let inbox: SharedFileInbox
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            // A file that arrived before this label mounted (a cold launch with the window suppressed).
            .onAppear { if !inbox.files.isEmpty { summon() } }
            .onChange(of: inbox.arrivals) { _, _ in summon() }
    }

    private func summon() {
        openWindow(id: M1K3App.mainWindowID)
        NSApp.activate()
    }
}
