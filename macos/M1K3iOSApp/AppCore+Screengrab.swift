//
//  AppCore+Screengrab.swift
//  M1K3iOS / M1K3visionOS
//
//  The mobile half of the App Store screengrab harness (M1K3Screengrab) — the
//  mirror of AppEnvironment+Screengrab on the Mac: seed the demo persona into
//  the isolated store root, and fire the plate's launch beat (voice mode, the
//  spoken hero answer with karaoke) once the brain is ready. Every entry point
//  is a no-op unless M1K3_SCREENGRAB=1 is in the launch environment.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.8 (seed pinned in
//  M1K3ScreengrabTests; the beat is verify-by-launch through the
//  M1K3iOSScreengrabUITests suite on a device), Prior: Unknown
//

import Foundation
import M1K3Chat
import M1K3Screengrab
import os

extension AppCore {
    private nonisolated static let screengrabLog = Logger(subsystem: "app.m1k3", category: "screengrab")

    /// Synchronous, from init, BEFORE `ChatSession` reads the most recent row.
    static func seedScreengrabHistory(into history: (any ChatHistoryPersisting)?, root: URL) {
        guard ScreengrabHarness.current.isActive, let history else { return }
        do {
            try DemoSeeder.seedHistory(into: history, root: root)
        } catch {
            screengrabLog.error("history seed failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Memories + documents ride the embedder, so they land as a launch task.
    func seedScreengrabKnowledgeIfActive(root: URL) {
        guard ScreengrabHarness.current.isActive else { return }
        // Detached, off the main actor — see the Mac twin: the embedder's first
        // embed must never block the main thread during launch.
        let memory = memoryStore, ingester = ingester, embedder = embedder
        Task.detached(priority: .utility) {
            do {
                try await DemoSeeder.seedKnowledge(memory: memory, ingester: ingester, embedder: embedder, root: root)
                Self.screengrabLog.notice("demo persona seeded under \(root.lastPathComponent, privacy: .public)")
            } catch {
                Self.screengrabLog.error("knowledge seed failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The plate's launch beat, fired by ChatScreen once the brain is ready.
    func performScreengrabBeat() async {
        let harness = ScreengrabHarness.current
        guard harness.isActive, harness.entersVoiceMode else { return }
        enterVoiceMode()
        guard harness.speaksHeroAnswer else { return }
        // Let the mode settle (avatar in, mic armed) before the karaoke line.
        try? await Task.sleep(for: .seconds(1.5))
        let line = DemoPersona.heroConversation[1].text
        speechHighlight.beginUtterance(text: line)
        await speech.speak(line)
    }
}
