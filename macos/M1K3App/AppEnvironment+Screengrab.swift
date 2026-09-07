//
//  AppEnvironment+Screengrab.swift
//  M1K3App
//
//  The Mac half of the App Store screengrab harness (M1K3Screengrab): seed the
//  demo persona into the isolated store root, and answer the per-plate launch
//  beats ContentView fires once the brain is ready (voice mode, the spoken
//  hero answer). Every entry point is a no-op unless
//  M1K3_SCREENGRAB=1 is in the launch environment.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.8 (seed pinned in
//  M1K3ScreengrabTests; the launch beats are verify-by-launch through the
//  M1K3ScreengrabUITests suite), Prior: Unknown
//

import Foundation
import M1K3Chat
import M1K3Screengrab
import os

extension AppEnvironment {
    private static let screengrabLog = Logger(subsystem: "app.m1k3", category: "screengrab")

    /// Synchronous, from init, BEFORE `ChatSession` reads the most recent row.
    static func seedScreengrabHistory(into history: (any ChatHistoryPersisting)?, root: URL) {
        guard ScreengrabHarness.current.isActive, let history else { return }
        do {
            try DemoSeeder.seedHistory(into: history, root: root)
        } catch {
            screengrabLog.error("history seed failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Memories + documents ride the embedder, so they land as a launch task;
    /// the Documents/Memories plates wait on their rows appearing.
    func seedScreengrabKnowledgeIfActive(root: URL) {
        guard ScreengrabHarness.current.isActive else { return }
        Task {
            do {
                try await DemoSeeder.seedKnowledge(
                    memory: memoryStore, ingester: ingester, embedder: embedder, root: root
                )
                refreshCounts()
                Self.screengrabLog.notice("demo persona seeded under \(root.lastPathComponent, privacy: .public)")
            } catch {
                Self.screengrabLog.error("knowledge seed failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The plate's launch beat, fired by ContentView once `isReady` flips.
    func performScreengrabBeat() async {
        let harness = ScreengrabHarness.current
        guard harness.isActive else { return }
        if harness.entersVoiceMode {
            enterVoiceMode()
            if harness.speaksHeroAnswer {
                // Let the mode settle (avatar in, mic armed) before the karaoke line.
                try? await Task.sleep(for: .seconds(1.5))
                await speak(DemoPersona.heroConversation[1].text)
            }
        }
        // brain-at-home: the suite opens Settings ▸ M1K3 ▸ Brain at Home, whose
        // section starts the pairing ceremony itself — no beat needed here.
    }
}
