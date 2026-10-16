//
//  TurnClauseSlot.swift
//  M1K3Chat
//
//  One clause a shell sets for the turn it is about to send and clears after:
//  the voice shells put the room line here (VoiceTurnPreparer) and the
//  responder's `voiceClauseProvider` reads it. M1K3Chat can't see M1K3Voice, so
//  the line crosses as a plain String.
//
//  `set` hands back a token and `clear` only clears its own clause, so a turn
//  that ends late can't wipe a newer turn's line.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-16, Confidence 0.85. Prior: Unknown.

import Foundation

public final class TurnClauseSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private var generation = 0

    public init() {}

    public var clause: String? {
        lock.withLock { stored }
    }

    @discardableResult
    public func set(_ clause: String?) -> Int {
        lock.withLock {
            generation += 1
            stored = clause
            return generation
        }
    }

    public func clear(_ token: Int) {
        lock.withLock {
            if generation == token { stored = nil }
        }
    }
}
