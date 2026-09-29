//
//  MCPAccessTokenTests.swift
//  M1K3CLICoreTests
//
//  The one shape M1K3's loopback access token takes, pinned from both ends:
//  what the app mints, what `m1k3 login` accepts from a paste, what the door
//  compares, and what Settings shows on screen.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-28, Confidence 0.9 (pure; the
//  randomness source is the system CSPRNG in production). Prior: none (new file).
//

import Foundation
@testable import M1K3CLICore
import Testing

/// A generator that repeats one byte, so a mint is predictable in a test.
private struct RepeatingGenerator: RandomNumberGenerator {
    let byte: UInt8
    mutating func next() -> UInt64 {
        UInt64(byte) * 0x0101_0101_0101_0101
    }
}

struct MCPAccessTokenTests {
    @Test("a minted token is the prefix plus 43 URL-safe characters — 256 bits, no padding")
    func mintShape() {
        var generator = SystemRandomNumberGenerator()
        let token = MCPAccessToken.mint(using: &generator)
        #expect(token.hasPrefix("m1k3_"))
        #expect(token.count == 5 + 43)
        #expect(MCPAccessToken.isWellFormed(token))
        #expect(!token.contains("="))
    }

    @Test("two mints from the system generator differ")
    func mintsDiffer() {
        var generator = SystemRandomNumberGenerator()
        #expect(MCPAccessToken.mint(using: &generator) != MCPAccessToken.mint(using: &generator))
    }

    @Test("the mint encodes the generator's bytes, base64url")
    func mintEncodesBytes() {
        var generator = RepeatingGenerator(byte: 0xFF)
        // 32 × 0xFF in base64url: 42 underscores and a final '8' (the last 2 bytes' 4 spare bits).
        #expect(MCPAccessToken.mint(using: &generator) == "m1k3_" + String(repeating: "_", count: 42) + "8")
    }

    @Test("only the exact shape is well-formed")
    func wellFormed() {
        let body = String(repeating: "a", count: 43)
        #expect(MCPAccessToken.isWellFormed("m1k3_" + body))
        #expect(!MCPAccessToken.isWellFormed(body), "no prefix")
        #expect(!MCPAccessToken.isWellFormed("m1k3_" + body.dropLast()), "short")
        #expect(!MCPAccessToken.isWellFormed("m1k3_" + body + "a"), "long")
        #expect(!MCPAccessToken.isWellFormed("m1k3_" + body.dropLast() + "+"), "base64, not base64url")
        #expect(!MCPAccessToken.isWellFormed("M1K3_" + body), "the prefix is lowercase")
        #expect(!MCPAccessToken.isWellFormed("m1k3_" + body.dropLast() + "é"), "ASCII only")
        #expect(!MCPAccessToken.isWellFormed(""))
    }

    @Test("a paste is forgiving about whitespace and the header around it")
    func parsePaste() {
        let token = "m1k3_" + String(repeating: "Ab-_", count: 10) + "xyz"
        #expect(MCPAccessToken.parse(pasted: token) == token)
        #expect(MCPAccessToken.parse(pasted: "  \(token)\n") == token)
        #expect(MCPAccessToken.parse(pasted: "Bearer \(token)") == token)
        #expect(MCPAccessToken.parse(pasted: "Authorization: Bearer \(token)") == token)
        #expect(MCPAccessToken.parse(pasted: "authorization: bearer \(token)\r\n") == token)
        #expect(MCPAccessToken.parse(pasted: "\"\(token)\"") == token, "copied with its quotes")
        #expect(MCPAccessToken.parse(pasted: "") == nil)
        #expect(MCPAccessToken.parse(pasted: "Bearer ") == nil)
        #expect(MCPAccessToken.parse(pasted: "not a token") == nil)
        #expect(MCPAccessToken.parse(pasted: "\(token) \(token)") == nil, "two tokens is not one")
    }

    @Test("the door reads the token out of an Authorization value — Bearer scheme only, case-insensitive")
    func bearerFromHeader() {
        let token = "m1k3_" + String(repeating: "q", count: 43)
        #expect(MCPAccessToken.bearer(fromAuthorization: "Bearer \(token)") == token)
        #expect(MCPAccessToken.bearer(fromAuthorization: "bearer \(token)") == token)
        #expect(MCPAccessToken.bearer(fromAuthorization: "  Bearer   \(token)  ") == token)
        #expect(MCPAccessToken.bearer(fromAuthorization: "Basic \(token)") == nil)
        #expect(MCPAccessToken.bearer(fromAuthorization: token) == nil, "a bare token has no scheme")
        #expect(MCPAccessToken.bearer(fromAuthorization: "Bearer") == nil)
        #expect(MCPAccessToken.bearer(fromAuthorization: "Bearer a b") == nil)
    }

    @Test("the header value is the Bearer form")
    func headerValue() {
        #expect(MCPAccessToken.headerValue("m1k3_x") == "Bearer m1k3_x")
        #expect(MCPAccessToken.headerName == "Authorization")
    }

    @Test("matching is exact — any byte, any length difference fails")
    func matches() {
        let token = "m1k3_" + String(repeating: "k", count: 43)
        #expect(MCPAccessToken.matches(token, expected: token))
        #expect(!MCPAccessToken.matches(String(token.dropLast()) + "K", expected: token))
        #expect(!MCPAccessToken.matches("x" + token.dropFirst(), expected: token))
        #expect(!MCPAccessToken.matches(String(token.dropLast()), expected: token))
        #expect(!MCPAccessToken.matches(token + "k", expected: token))
        #expect(!MCPAccessToken.matches("", expected: token))
    }

    @Test("on screen the token is masked: the prefix, dots, and its last four")
    func masked() {
        let token = "m1k3_" + String(repeating: "a", count: 39) + "WXYZ"
        #expect(MCPAccessToken.masked(token) == "m1k3_••••••••WXYZ")
        #expect(!MCPAccessToken.masked(token).contains(String(repeating: "a", count: 5)))
        #expect(MCPAccessToken.masked("short") == "••••••••", "never echo something that isn't a token")
    }

    @Test("redacting masks every occurrence of the token in text bound for the screen")
    func redacting() {
        let token = "m1k3_" + String(repeating: "r", count: 39) + "ABCD"
        let line = "claude mcp add m1k3 url --header \"Authorization: Bearer \(token)\" (again: \(token))"
        let shown = MCPAccessToken.redacting(line, token: token)
        #expect(!shown.contains(token))
        #expect(shown.components(separatedBy: "m1k3_••••••••ABCD").count == 3, "both occurrences masked")
        #expect(MCPAccessToken.redacting("nothing secret", token: token) == "nothing secret")
        #expect(MCPAccessToken.redacting("x", token: "") == "x", "an empty token redacts nothing")
    }

    @Test("an argument that looks like a token is shown only masked")
    func maskedIfToken() {
        let token = "m1k3_" + String(repeating: "p", count: 39) + "WXYZ"
        #expect(MCPAccessToken.maskedIfToken(token) == "m1k3_••••••••WXYZ")
        #expect(MCPAccessToken.maskedIfToken("m1k3_short") == "m1k3_••••••••", "a token-ish prefix is never echoed whole")
        #expect(MCPAccessToken.maskedIfToken("8o8o") == "8o8o")
    }
}
