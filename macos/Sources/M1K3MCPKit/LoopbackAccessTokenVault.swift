//
//  LoopbackAccessTokenVault.swift
//  M1K3MCPKit
//
//  How the app comes by the loopback listener's access token (#270 slice 3).
//  The Keychain sits behind two closures so the rules are pinned here: keep a
//  well-formed token, mint over a missing or mangled one (saved BEFORE it is
//  served — an unsaved token dies at relaunch and takes every client's config
//  with it), and when the Keychain can't be read, don't start at all. A read
//  failure is never "no token": minting over it would silently break every
//  client the moment the Keychain came back.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-28, Confidence 0.9 (pinned in
//  LoopbackAccessTokenVaultTests; the adapter is verify-by-launch). Prior: none (new file).
//

import Foundation
import M1K3CLICore
import Synchronization

public enum LoopbackAccessTokenVault {
    public static func loadOrMint(
        read: () throws -> String?,
        save: (String) throws -> Void,
        mint: () -> String = systemMint
    ) throws -> String {
        if let stored = try read(), MCPAccessToken.isWellFormed(stored) { return stored }
        let fresh = mint()
        try save(fresh)
        return fresh
    }

    /// A new token, saved; the caller swaps it in only once this returns.
    public static func rotate(save: (String) throws -> Void, mint: () -> String = systemMint) throws -> String {
        let fresh = mint()
        try save(fresh)
        return fresh
    }

    /// The system CSPRNG (SystemRandomNumberGenerator is arc4random on Apple platforms).
    public static func systemMint() -> String {
        var generator = SystemRandomNumberGenerator()
        return MCPAccessToken.mint(using: &generator)
    }
}

/// The token the listener checks, shared between the host (which loads and
/// rotates it) and the listener's per-request read. Empty until the host loads
/// one — and an empty box answers with a token nobody holds, so a listener
/// that somehow started first refuses everything rather than admitting it.
public final class LoopbackAccessTokenBox: Sendable {
    private let token = Mutex<String?>(nil)
    /// Minted once for the box's lifetime and never handed to anyone — fixed,
    /// not re-rolled per comparison; nobody can present what nobody was given.
    private let unknowable = LoopbackAccessTokenVault.systemMint()

    public init() {}

    public func set(_ newToken: String) {
        token.withLock { $0 = newToken }
    }

    public func current() -> String {
        token.withLock { $0 } ?? unknowable
    }
}
