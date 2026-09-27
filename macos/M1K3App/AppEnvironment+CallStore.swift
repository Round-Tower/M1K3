//
//  AppEnvironment+CallStore.swift
//  M1K3App
//
//  The encrypted call-store factory, lifted out of AppEnvironment so the
//  composition root stays under SwiftLint's file_length ceiling. These are pure
//  static assembly helpers — they touch no instance state — so a separate-file
//  extension needs no access widening. The one diagnostic the factory emits uses
//  this file's own `calls`-category logger rather than reaching for the class's
//  private one (same category, so the call-store trail still reads as one stream).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.9, Prior: Unknown
//  (makeCallPersistence/storeURL/NullCallPersistence originate in the calls
//  subsystem work; moved verbatim here, only the logger reference changed).
//  Review: Kev + claude-fable-5.1, 2026-09-07 — `storeURL()` routes through `ScreengrabHarness.dataRoot`: under M1K3_SCREENGRAB=1
//  every store opens beside the live root (`M1K3-screengrab`), never in it. Confidence now 0.9.
//  Review: Kev + claude-opus-5-5, 2026-09-27 — #407: the key is read on the store's first save or
//  read (`DeferredKeyCallCoder`), not while the app is built — launch and the MCP listener no longer
//  wait on Touch ID. A dismissed prompt now fails that save (the recording stays parked) instead of
//  dropping the whole session to an in-memory store, where a recovered call was consumed and then
//  lost at quit. Confidence 0.8 (the prompt timing is verified live, not in a test).
//  Review: same day (2), #440 review — `offMainCallStore`: saves and the list load run detached, so
//  the first decrypt's Touch ID sheet never blocks the main actor (and MCP behind it). Confidence 0.8.

import CryptoKit
import Foundation
import M1K3Calls
import M1K3Screengrab
import os

private let callStoreLog = Logger(subsystem: "app.m1k3", category: "calls")

extension AppEnvironment {
    /// Build the encrypted call store. Its key is read on first use, not here (#407): the
    /// key sits behind Touch ID, and reading it during construction held launch — the MCP
    /// listener included — on the prompt. Counting and deleting never decrypt, so the first
    /// prompt is the first call saved or opened. A GRDB open failure falls back to an
    /// in-memory store, so a hiccup degrades the calls feature rather than the app.
    static func makeCallPersistence(at url: URL) -> any CallPersistence {
        // Screengrab harness: the call-encryption key lives in the Keychain under
        // the live app's signing identity; a test build reading it gets a password
        // prompt IN the frame. Calls are not a plate — use the inert store.
        if ScreengrabHarness.current.isActive { return NullCallPersistence() }
        let coder = DeferredKeyCallCoder(readKey: readCallKey)
        do {
            return try GRDBCallPersistence(path: url.path, coder: coder)
        } catch {
            callStoreLog.error("call store fell back to non-persistent: \(error, privacy: .public)")
            return (try? GRDBCallPersistence()) ?? NullCallPersistence()
        }
    }

    /// The call-encryption key, gated behind Touch ID (login-password fallback) via a
    /// .userPresence Keychain access control. Runs on the store's first save or read, and
    /// again only after a failure: a dismissed prompt means that save throws (a recording
    /// stays parked for the next try) and the next use asks again.
    private nonisolated static func readCallKey() throws -> SymmetricKey {
        let provider = StoredKeyProvider(store: KeychainKeyStore(protection: .userPresence))
        do {
            // One-time, flag-guarded migration: a key written before this gate
            // existed is unprotected; reassert upgrades it IN PLACE (same bytes, so
            // existing encrypted calls stay decryptable). Guarded because reassert
            // reads the key — against an already-protected item that read would itself
            // fire Touch ID, so running it every time means TWO prompts. Once only.
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: callKeyProtectionMigratedKey) {
                try provider.reassertProtection()
                defaults.set(true, forKey: callKeyProtectionMigratedKey)
            }
            return try provider.symmetricKey()
        } catch {
            // Undiagnosable otherwise: a dismissed Touch ID lands here as .userCancelled.
            callStoreLog.error("call key unavailable: \(error, privacy: .public)")
            throw error
        }
    }

    /// Store work that may decrypt, run off the main actor. The first decrypt reads the key
    /// behind Touch ID, synchronously; on the main actor the waiting sheet stalled the UI and
    /// every MCP request queued behind it — #407 again, whenever a parked recording was
    /// recovered at launch (#440 review). Count and delete never decrypt and stay put.
    nonisolated static func offMainCallStore<T: Sendable>(
        _ persistence: any CallPersistence,
        _ work: @escaping @Sendable (any CallPersistence) throws -> T
    ) async throws -> T {
        try await Task.detached { try work(persistence) }.value
    }

    static func storeURL() throws -> URL {
        let fileManager = FileManager.default
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // The screengrab harness (M1K3_SCREENGRAB=1) moves every store to a
        // SIBLING root so a capture run never reads or writes the live one.
        let dir = ScreengrabHarness.current.dataRoot(
            live: base.appendingPathComponent("M1K3", isDirectory: true)
        )
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("knowledge.sqlite")
    }
}

/// Last-resort no-op store so a (near-impossible) persistence-init failure leaves
/// the app running with the calls feature simply inert, never crashing.
private struct NullCallPersistence: CallPersistence {
    func save(_: CallSession) throws {}
    func load(id _: UUID) throws -> CallSession? {
        nil
    }

    func loadAll() throws -> [CallSession] {
        []
    }

    func delete(id _: UUID) throws -> Bool {
        false
    }
}
