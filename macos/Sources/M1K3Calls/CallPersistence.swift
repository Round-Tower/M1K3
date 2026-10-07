//
//  CallPersistence.swift
//  M1K3Calls
//
//  The storage seam for call sessions — save / load / list / delete. A protocol so
//  the store is swappable and testable; the concrete GRDB store conforms. Privacy
//  is a property of the *coder* (plain JSON vs AES-GCM), not the store, so "encrypted
//  at rest" is a one-line swap with no store changes.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85,
//  Prior: internal call-pipeline project, CallPersistence (Kev) — neutral, coder-pluggable.
//  Review: Kev + claude-opus-5-5, 2026-10-07 — `loadReadable`: one undecodable row no longer
//  blanks the log (the header read 13, the list "No calls yet"). A row is skipped and counted,
//  never deleted; a key that can't be read still throws. Confidence 0.85.

import Foundation

public protocol CallPersistence: Sendable {
    /// Insert or replace a call by id.
    func save(_ session: CallSession) throws
    /// Load one call, or nil if absent.
    func load(id: UUID) throws -> CallSession?
    /// All calls, newest first.
    func loadAll() throws -> [CallSession]
    /// Delete a call; returns whether a row was removed.
    @discardableResult
    func delete(id: UUID) throws -> Bool

    /// Number of stored calls. Stores should override with a cheap `COUNT(*)` —
    /// the default decodes (and so decrypts) every row just to count, which is the
    /// thing we're trying to avoid on the hot count path.
    func count() throws -> Int
    /// The calls that decode, newest first, and how many rows didn't. An unreadable row is
    /// skipped and kept; an error that isn't a row's own (the key can't be read) throws.
    func loadReadable() throws -> CallLoadResult
}

public extension CallPersistence {
    func count() throws -> Int {
        try loadAll().count
    }

    /// Strict by default: a store that can't tell one row from another loads all or nothing.
    func loadReadable() throws -> CallLoadResult {
        try CallLoadResult(calls: loadAll(), unreadable: 0)
    }
}

/// What the call log can show, and what it can't.
public struct CallLoadResult: Sendable, Equatable {
    public let calls: [CallSession]
    /// Rows kept on disk that wouldn't decode (sealed under another key, or an old shape).
    public let unreadable: Int

    public init(calls: [CallSession], unreadable: Int) {
        self.calls = calls
        self.unreadable = unreadable
    }

    /// nil when the list shows everything.
    public var statusLine: String? {
        switch unreadable {
        case 0: nil
        case 1: "1 call couldn’t be opened — it’s kept, not deleted."
        default: "\(unreadable) calls couldn’t be opened — they’re kept, not deleted."
        }
    }
}

public enum CallPersistenceError: Error, Sendable, Equatable {
    case encryptionFailed
    case decodingFailed
}
