//
//  LoopbackAccessTokenVaultTests.swift
//  M1K3MCPKitTests
//
//  How the app comes by its access token at MCP start (#270 slice 3): keep a
//  good one, mint over a missing or mangled one, and never start — never
//  overwrite — when the Keychain can't be read.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-28, Confidence 0.9 (pure; the
//  Keychain adapter behind the closures is verify-by-launch). Prior: none (new file).
//

import Foundation
import M1K3CLICore
@testable import M1K3MCPKit
import Testing

private struct KeychainLocked: Error {}

private final class FakeKeychain: @unchecked Sendable {
    var stored: String?
    var readError: (any Error)?
    var saveError: (any Error)?
    private(set) var saves: [String] = []

    init(_ stored: String? = nil) {
        self.stored = stored
    }

    func read() throws -> String? {
        if let readError { throw readError }
        return stored
    }

    func save(_ token: String) throws {
        if let saveError { throw saveError }
        saves.append(token)
        stored = token
    }
}

struct LoopbackAccessTokenVaultTests {
    private let good = "m1k3_" + String(repeating: "g", count: 43)
    private let fresh = "m1k3_" + String(repeating: "f", count: 43)

    @Test("a well-formed stored token is kept — no mint, no write")
    func keepsGoodToken() throws {
        let keychain = FakeKeychain(good)
        let token = try LoopbackAccessTokenVault.loadOrMint(read: keychain.read, save: keychain.save, mint: { fresh })
        #expect(token == good)
        #expect(keychain.saves.isEmpty)
    }

    @Test("no stored token: a fresh one is minted and saved before it is used")
    func mintsWhenMissing() throws {
        let keychain = FakeKeychain()
        let token = try LoopbackAccessTokenVault.loadOrMint(read: keychain.read, save: keychain.save, mint: { fresh })
        #expect(token == fresh)
        #expect(keychain.saves == [fresh])
    }

    @Test("a mangled stored value is replaced, not served")
    func replacesMangled() throws {
        let keychain = FakeKeychain("hunter2")
        let token = try LoopbackAccessTokenVault.loadOrMint(read: keychain.read, save: keychain.save, mint: { fresh })
        #expect(token == fresh)
        #expect(keychain.saves == [fresh])
    }

    @Test("a Keychain that can't be read fails closed — and never overwrites what might be there")
    func unreadableFailsClosed() {
        let keychain = FakeKeychain(good)
        keychain.readError = KeychainLocked()
        #expect(throws: KeychainLocked.self) {
            try LoopbackAccessTokenVault.loadOrMint(read: keychain.read, save: keychain.save, mint: { fresh })
        }
        #expect(keychain.saves.isEmpty)
    }

    @Test("a minted token that can't be saved is never served — every client would lose it at relaunch")
    func unsavedMintFailsClosed() {
        let keychain = FakeKeychain()
        keychain.saveError = KeychainLocked()
        #expect(throws: KeychainLocked.self) {
            try LoopbackAccessTokenVault.loadOrMint(read: keychain.read, save: keychain.save, mint: { fresh })
        }
    }

    @Test("rotate saves a new token and hands it back; a failed save leaves the old one in force")
    func rotate() throws {
        let keychain = FakeKeychain(good)
        #expect(try LoopbackAccessTokenVault.rotate(save: keychain.save, mint: { fresh }) == fresh)
        #expect(keychain.stored == fresh)

        let stuck = FakeKeychain(good)
        stuck.saveError = KeychainLocked()
        #expect(throws: KeychainLocked.self) {
            try LoopbackAccessTokenVault.rotate(save: stuck.save, mint: { fresh })
        }
        #expect(stuck.stored == good)
    }

    @Test("an empty box answers with a token nobody holds; a set token replaces it at once")
    func box() {
        let box = LoopbackAccessTokenBox()
        #expect(MCPAccessToken.isWellFormed(box.current()), "never empty — an empty expected token must not exist")
        #expect(box.current() != good)
        box.set(good)
        #expect(box.current() == good)
        box.set(fresh)
        #expect(box.current() == fresh)
    }

    @Test("the production mint is a well-formed token")
    func productionMint() {
        #expect(MCPAccessToken.isWellFormed(LoopbackAccessTokenVault.systemMint()))
    }
}
