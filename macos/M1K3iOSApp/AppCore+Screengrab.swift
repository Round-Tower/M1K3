//
//  AppCore+Screengrab.swift
//  M1K3iOS / M1K3visionOS
//
//  The mobile half of the App Store screengrab harness (M1K3Screengrab) — the
//  mirror of AppEnvironment+Screengrab on the Mac: seed the demo persona into
//  the isolated store root, hand the voice plates the open mic, and fire the
//  plate's launch beat (voice mode) once the brain is ready. Every entry point
//  is a no-op unless M1K3_SCREENGRAB=1 is in the launch environment.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.8 (seed pinned in
//  M1K3ScreengrabTests; the beat is verify-by-launch through the
//  M1K3iOSScreengrabUITests suite on a device), Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-09 — the open mic comes to the phone (`screengrabTranscriber`, the Mac's seam): the
//  speaking plate is a REAL turn through the loop — a direct `speak` never reached `.speaking`, so the phone's
//  first run shot "Listening…" for it. Confidence now 0.8.
//

import Foundation
import M1K3BrainLink
import M1K3Chat
import M1K3LogCore
import M1K3Screengrab
import M1K3Voice
import os

/// The harness's Brain at Home key store: in-memory, process-lifetime, so a
/// capture never reads the device's real PSK. `@unchecked Sendable`: every
/// mutable member is read and written under `lock`.
final class ScreengrabBrainKeyStore: BrainKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    func setKey(_ key: Data, identity: String) throws {
        lock.withLock { keys[identity] = key }
    }

    func key(identity: String) -> Data? {
        lock.withLock { keys[identity] }
    }

    func removeKey(identity: String) {
        lock.withLock { _ = keys.removeValue(forKey: identity) }
    }
}

extension AppCore {
    private nonisolated static let screengrabLog = M1K3Log.logger(.screengrab)

    /// The voice plates' recogniser: an open mic, no TCC, the hero question as a
    /// live partial (listening) or a submitted turn (speaking). Nil otherwise.
    nonisolated static func screengrabTranscriber() -> (any TranscriptionProvider)? {
        let harness = ScreengrabHarness.current
        guard harness.isActive, harness.entersVoiceMode else { return nil }
        return OpenMicTranscriber(partial: harness.livePartial, submits: harness.submitsHeroQuestion)
    }

    /// Pairing persistence: the real defaults + Keychain, or — under the harness —
    /// a throwaway defaults suite and an in-memory key store, so neither the
    /// owner's paired Mac nor its key can reach a plate.
    static func makeBrainLinkStore() -> PairedBrainStore {
        guard ScreengrabHarness.current.isActive else { return PairedBrainStore() }
        let defaults = UserDefaults(suiteName: "app.m1k3.screengrab") ?? .standard
        return PairedBrainStore(defaults: defaults, keys: ScreengrabBrainKeyStore())
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
    /// The speaking plate needs no beat of its own: the open mic submits the
    /// hero question and the loop answers and speaks it (karaoke and all).
    func performScreengrabBeat() {
        let harness = ScreengrabHarness.current
        guard harness.isActive, harness.entersVoiceMode else { return }
        enterVoiceMode()
    }
}
