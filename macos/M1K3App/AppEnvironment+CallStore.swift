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

import Foundation
import M1K3Calls
import M1K3Screengrab
import os

private let callStoreLog = Logger(subsystem: "app.m1k3", category: "calls")

extension AppEnvironment {
    /// Build the encrypted call store. Falls back to an in-memory (non-persistent)
    /// store if the Keychain key can't be obtained, so a key hiccup degrades the
    /// calls feature rather than crashing the app.
    static func makeCallPersistence(at url: URL) -> any CallPersistence {
        // Screengrab harness: the call-encryption key lives in the Keychain under
        // the live app's signing identity; a test build reading it gets a password
        // prompt IN the frame. Calls are not a plate — use the inert store.
        if ScreengrabHarness.current.isActive { return NullCallPersistence() }
        do {
            // The call-encryption key is gated behind Touch ID (login-password
            // fallback) via a .userPresence Keychain access control, read once here
            // at call-store construction → one biometric prompt per launch.
            let provider = StoredKeyProvider(store: KeychainKeyStore(protection: .userPresence))
            // One-time, flag-guarded migration: a key written before this gate
            // existed is unprotected; reassert upgrades it IN PLACE (same bytes, so
            // existing encrypted calls stay decryptable). Guarded because reassert
            // reads the key — against an already-protected item that read would itself
            // fire Touch ID, so running it every launch means TWO prompts. Once only.
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: callKeyProtectionMigratedKey) {
                try provider.reassertProtection()
                defaults.set(true, forKey: callKeyProtectionMigratedKey)
            }
            let key = try provider.symmetricKey()
            return try GRDBCallPersistence(path: url.path, coder: EncryptedCallCoder(key: key))
        } catch {
            // A key failure degrades calls to a non-persistent store rather than
            // crashing the app. Log it — an otherwise silently-inert calls feature is
            // undiagnosable (a dismissed Touch ID lands here as .userCancelled).
            callStoreLog.error("call store fell back to non-persistent: \(error, privacy: .public)")
            return (try? GRDBCallPersistence()) ?? NullCallPersistence()
        }
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
