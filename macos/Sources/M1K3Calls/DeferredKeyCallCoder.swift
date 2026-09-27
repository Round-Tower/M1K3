//
//  DeferredKeyCallCoder.swift
//  M1K3Calls
//
//  The encrypted coder with its key read on first use (#407). The Calls key sits behind
//  Touch ID; reading it while the app was being built held launch — and the MCP listener —
//  on the prompt, so an unattended relaunch left M1K3 deaf until someone touched the sensor,
//  and everyone paid the prompt whether they record calls or not. A store over this coder
//  counts and deletes without it (neither decrypts); the first save or read asks.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.85 (the ciphertext is the eager
//  coder's, test-pinned both ways). Prior: none (new file).
//

import CryptoKit
import Foundation
import Synchronization

public final class DeferredKeyCallCoder: CallSessionCoder {
    private let readKey: @Sendable () throws -> SymmetricKey
    private let coder = Mutex<EncryptedCallCoder?>(nil)

    /// `readKey` runs on the first encode or decode, and again only if it threw: a
    /// dismissed prompt is asked again next time, never kept for the session.
    public init(readKey: @escaping @Sendable () throws -> SymmetricKey) {
        self.readKey = readKey
    }

    public func encode(_ session: CallSession) throws -> Data {
        try resolved().encode(session)
    }

    public func decode(_ data: Data) throws -> CallSession {
        try resolved().decode(data)
    }

    /// Held across the read, so callers racing the first use share one prompt.
    private func resolved() throws -> EncryptedCallCoder {
        try coder.withLock { coder in
            if let coder { return coder }
            let made = try EncryptedCallCoder(key: readKey())
            coder = made
            return made
        }
    }
}
