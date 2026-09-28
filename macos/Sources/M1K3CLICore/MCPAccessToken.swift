//
//  MCPAccessToken.swift
//  M1K3CLICore
//
//  The access token on M1K3's loopback MCP listener (#270 slice 3). One shape,
//  shared by the app that mints and checks it and the `m1k3` CLI that carries
//  it: `m1k3_` plus 256 random bits in base64url. The prefix is there so a
//  token pasted into a chat, a gist or a commit is recognisable as a secret.
//
//  What it is for: opportunistic callers — a stray script or a postinstall
//  that finds port 4242 open — and session eviction (a caller without the
//  token can't reach the initialize that rebuilds the live session). What it
//  is not: a defence against malware running as you, which can read any
//  client's config file. The toggles in slice 1 cover the dangerous tools for
//  every caller; this narrows who is a caller.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-28, Confidence 0.9 (pure; every
//  rule pinned in MCPAccessTokenTests). Prior: none (new file).
//

import Foundation

public enum MCPAccessToken {
    public static let prefix = "m1k3_"
    public static let headerName = "Authorization"
    /// 32 random bytes → 43 base64url characters, unpadded.
    static let bodyLength = 43

    /// A fresh token. Production passes `SystemRandomNumberGenerator`, which
    /// is the system CSPRNG on Apple platforms.
    public static func mint(using generator: inout some RandomNumberGenerator) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for _ in 0 ..< 4 {
            withUnsafeBytes(of: generator.next()) { bytes.append(contentsOf: $0) }
        }
        let body = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return prefix + body
    }

    public static func isWellFormed(_ candidate: String) -> Bool {
        guard candidate.hasPrefix(prefix) else { return false }
        let body = candidate.utf8.dropFirst(prefix.utf8.count)
        return body.count == bodyLength && body.allSatisfy(isBase64URL)
    }

    /// What `m1k3 login` makes of a paste: surrounding whitespace, quotes and
    /// an `Authorization:` / `Bearer` lead-in are forgiven; anything else must
    /// be exactly one well-formed token.
    public static func parse(pasted: String) -> String? {
        var text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.first == "\"", text.last == "\"" {
            text = String(text.dropFirst().dropLast())
        }
        if text.lowercased().hasPrefix("authorization:") {
            text = String(text.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces)
        }
        if let bearer = bearer(fromAuthorization: text) { return bearer }
        return isWellFormed(text) ? text : nil
    }

    /// The token in an `Authorization` value, when the scheme is Bearer and
    /// exactly one credential follows. Not judged for shape here — the door
    /// compares it, and a malformed one simply doesn't match.
    public static func bearer(fromAuthorization value: String) -> String? {
        let parts = value.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let credential = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return credential.isEmpty ? nil : credential
    }

    public static func headerValue(_ token: String) -> String {
        "Bearer \(token)"
    }

    /// Constant-time over the expected token's bytes: how far a guess matched
    /// never shows in how long the answer took. Length is not secret (every
    /// token is 48 bytes), so a length miss fails at once.
    public static func matches(_ presented: String, expected: String) -> Bool {
        let lhs = Array(presented.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in rhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    /// How Settings shows it: enough to tell two tokens apart, never enough to
    /// use one. Copy is the only way to get the whole thing.
    public static func masked(_ token: String) -> String {
        guard isWellFormed(token) else { return "••••••••" }
        return prefix + "••••••••" + token.suffix(4)
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }
}
