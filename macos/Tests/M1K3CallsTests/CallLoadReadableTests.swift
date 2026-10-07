//
//  CallLoadReadableTests.swift
//  M1K3CallsTests
//
//  One unreadable call must not blank the call log. Kev, 2026-10-07: the Calls header read
//  13 while the list read "No calls yet" — `loadAll` decodes every row inside one `map`, so a
//  single undecodable payload threw the whole load, and the app turned that into `[]`.
//  `loadReadable` skips (never deletes) an undecodable row and counts it; a key that can't be
//  read at all is a different fact — the whole log is locked — and still throws.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85, Prior: none (new file).
//

import CryptoKit
import Foundation
import GRDB
@testable import M1K3Calls
import Testing

private func call(_ title: String, at seconds: TimeInterval) -> CallSession {
    CallSession(
        startedAt: Date(timeIntervalSince1970: seconds),
        title: title,
        segments: [CallTranscriptSegment(text: "Line for \(title)", startTime: 0, speaker: "A")],
        speakers: [],
        fullSummary: nil
    )
}

private func temporaryStorePath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
}

private struct KeyUnavailable: Error {}

struct CallLoadReadableTests {
    @Test("a row sealed under another key is skipped and counted; the rest still load, newest first")
    func undecodableRowIsSkipped() throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let key = SymmetricKey(size: .bits256)
        let store = try GRDBCallPersistence(path: path, coder: EncryptedCallCoder(key: key))
        try store.save(call("Older", at: 10))
        try store.save(call("Newer", at: 30))
        // A row this key can't open, sitting between the two readable ones.
        let stranger = try GRDBCallPersistence(path: path, coder: EncryptedCallCoder(key: SymmetricKey(size: .bits256)))
        try stranger.save(call("Sealed elsewhere", at: 20))

        let result = try store.loadReadable()
        #expect(result.calls.map(\.title) == ["Newer", "Older"])
        #expect(result.unreadable == 1)
        // Skipped, never deleted: the row is still there for a later fix to recover.
        #expect(try store.count() == 3)
    }

    @Test("an old or corrupt shape under the RIGHT key, and garbage ciphertext, both count as unreadable")
    func corruptShapesAreUnreadable() throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let key = SymmetricKey(size: .bits256)
        let store = try GRDBCallPersistence(path: path, coder: EncryptedCallCoder(key: key))
        try store.save(call("Good", at: 30))
        let raw = try DatabaseQueue(path: path)
        // Sealed correctly, but the plaintext isn't a CallSession (an old or broken shape).
        let wrongShape = try #require(AES.GCM.seal(Data(#"{"legacy":true}"#.utf8), using: key).combined)
        // Not a sealed box at all.
        let garbage = Data([0x01, 0x02, 0x03])
        try raw.write { db in
            for (seconds, payload) in [(20.0, wrongShape), (10.0, garbage)] {
                try db.execute(
                    sql: "INSERT INTO call_sessions (id, started_at, payload) VALUES (?, ?, ?)",
                    arguments: [UUID().uuidString, seconds, payload]
                )
            }
        }
        let result = try store.loadReadable()
        #expect(result.calls.map(\.title) == ["Good"])
        #expect(result.unreadable == 2)
    }

    @Test("every row unreadable: an empty list that still counts them, so the screen can say why")
    func allUnreadable() throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let old = try GRDBCallPersistence(path: path, coder: EncryptedCallCoder(key: SymmetricKey(size: .bits256)))
        try old.save(call("One", at: 1))
        try old.save(call("Two", at: 2))
        let rekeyed = try GRDBCallPersistence(path: path, coder: EncryptedCallCoder(key: SymmetricKey(size: .bits256)))
        let result = try rekeyed.loadReadable()
        #expect(result.calls.isEmpty)
        #expect(result.unreadable == 2)
        #expect(result.statusLine == "2 calls couldn’t be opened — they’re kept, not deleted.")
    }

    @Test("a key that can't be read throws: the log is locked, not every row broken")
    func unreadableKeyThrows() throws {
        let path = temporaryStorePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try GRDBCallPersistence(path: path, coder: EncryptedCallCoder(key: SymmetricKey(size: .bits256)))
            .save(call("Any", at: 1))
        let locked = try GRDBCallPersistence(
            path: path, coder: DeferredKeyCallCoder(readKey: { throw KeyUnavailable() })
        )
        #expect(throws: KeyUnavailable.self) { _ = try locked.loadReadable() }
    }

    @Test("a clean store reports nothing unreadable; an empty one is empty")
    func cleanAndEmpty() throws {
        let store = try GRDBCallPersistence(coder: JSONCallCoder())
        #expect(try store.loadReadable() == CallLoadResult(calls: [], unreadable: 0))
        try store.save(call("Only", at: 1))
        let result = try store.loadReadable()
        #expect(result.calls.count == 1)
        #expect(result.unreadable == 0)
    }

    @Test("a store without its own override loads strictly through loadAll, nothing unreadable")
    func protocolDefault() throws {
        struct Fixed: CallPersistence {
            func save(_: CallSession) throws {}
            func load(id _: UUID) throws -> CallSession? {
                nil
            }

            func loadAll() throws -> [CallSession] {
                [call("Fixed", at: 1)]
            }

            func delete(id _: UUID) throws -> Bool {
                false
            }
        }
        let result = try Fixed().loadReadable()
        #expect(result.calls.map(\.title) == ["Fixed"])
        #expect(result.unreadable == 0)
    }

    @Test("the status line names what the list can't show, and is silent when it shows everything")
    func statusLine() {
        #expect(CallLoadResult(calls: [], unreadable: 0).statusLine == nil)
        #expect(CallLoadResult(calls: [call("A", at: 1)], unreadable: 1).statusLine
            == "1 call couldn’t be opened — it’s kept, not deleted.")
        #expect(CallLoadResult(calls: [], unreadable: 3).statusLine
            == "3 calls couldn’t be opened — they’re kept, not deleted.")
    }
}
