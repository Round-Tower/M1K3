//
//  DeferredKeyCallCoderTests.swift
//  M1K3CallsTests
//
//  #407: the Calls key sits behind Touch ID, and reading it while the app was being
//  built held launch (and the MCP listener) on the prompt until someone touched the
//  sensor. The coder now reads it on first encode or decode, once; a failed read (a
//  dismissed prompt) is retried next time rather than kept.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.85 (pure; the prompt itself
//  is the Keychain's, verified live). Prior: none (new file).
//

import CryptoKit
import Foundation
@testable import M1K3Calls
import Synchronization
import Testing

private final class KeyReads: Sendable {
    let count = Mutex(0)
    let failuresLeft: Mutex<Int>
    let key = SymmetricKey(size: .bits256)

    init(failFirst: Int = 0) {
        failuresLeft = Mutex(failFirst)
    }

    func read() throws -> SymmetricKey {
        count.withLock { $0 += 1 }
        let fail = failuresLeft.withLock { left -> Bool in
            guard left > 0 else { return false }
            left -= 1
            return true
        }
        if fail { throw CancellationError() }
        return key
    }
}

private func session() -> CallSession {
    CallSession(startedAt: Date(timeIntervalSince1970: 1_000_000), title: "Standup", segments: [])
}

struct DeferredKeyCallCoderTests {
    @Test("#407: building the coder, or a store over it, reads no key")
    func noReadAtConstruction() throws {
        let reads = KeyReads()
        let store = try GRDBCallPersistence(coder: DeferredKeyCallCoder(readKey: reads.read))
        #expect(try store.count() == 0)
        #expect(try store.delete(id: UUID()) == false)
        #expect(reads.count.withLock { $0 } == 0)
    }

    @Test("the key is read once, on first use, and round-trips")
    func readOnceOnFirstUse() throws {
        let reads = KeyReads()
        let store = try GRDBCallPersistence(coder: DeferredKeyCallCoder(readKey: reads.read))
        let call = session()
        try store.save(call)
        #expect(try store.load(id: call.id)?.title == "Standup")
        #expect(try store.loadAll().count == 1)
        #expect(try store.count() == 1)
        #expect(reads.count.withLock { $0 } == 1)
    }

    @Test("a failed read (a dismissed prompt) is not kept: the next use asks again")
    func failedReadRetries() throws {
        let reads = KeyReads(failFirst: 1)
        let coder = DeferredKeyCallCoder(readKey: reads.read)
        #expect(throws: CancellationError.self) { try coder.encode(session()) }
        let data = try coder.encode(session())
        #expect(try coder.decode(data).title == "Standup")
        #expect(reads.count.withLock { $0 } == 2)
    }

    @Test("it encrypts exactly as the eager coder does: either one reads the other's rows")
    func matchesEagerCoder() throws {
        let reads = KeyReads()
        let eager = EncryptedCallCoder(key: reads.key)
        let deferred = DeferredKeyCallCoder(readKey: reads.read)
        #expect(try deferred.decode(eager.encode(session())).title == "Standup")
        #expect(try eager.decode(deferred.encode(session())).title == "Standup")
    }
}
