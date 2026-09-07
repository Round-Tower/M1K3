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
import M1K3Calls
import M1K3Chat
import M1K3LogCore
import M1K3Screengrab
import os

/// The harness's key store: in-memory, process-lifetime. The Keychain items the
/// live app owns (call key, script approvals, Brain at Home keys) are ACL'd to its
/// signing identity, so a test build reading them gets a password prompt IN the
/// frame — and none of them is a plate.
final class ScreengrabKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func data(forAccount account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    func setData(_ data: Data, forAccount account: String) throws {
        lock.withLock { items[account] = data }
    }

    func removeData(forAccount account: String) throws {
        _ = lock.withLock { items.removeValue(forKey: account) }
    }
}

extension AppEnvironment {
    private nonisolated static let screengrabLog = M1K3Log.logger(.screengrab)
    private nonisolated static let screengrabKeys = ScreengrabKeyStore()

    /// The Keychain for every ordinary launch; the in-memory store under the harness.
    nonisolated static func makeKeyStore(protection: KeychainKeyStore.Protection = .afterFirstUnlock) -> any KeyStore {
        ScreengrabHarness.current.isActive ? screengrabKeys : KeychainKeyStore(protection: protection)
    }

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
        // DETACHED: a plain Task here inherits the main actor, and the MLX
        // embedder's first embed (model load) would then block the main thread
        // for tens of seconds — long enough for XCTest's launch to give up on
        // the app ever coming foreground.
        let memory = memoryStore, ingester = ingester, embedder = embedder
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await DemoSeeder.seedKnowledge(memory: memory, ingester: ingester, embedder: embedder, root: root)
                await self?.refreshCounts()
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
