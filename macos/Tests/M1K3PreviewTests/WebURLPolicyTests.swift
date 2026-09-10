//
//  WebURLPolicyTests.swift
//  M1K3PreviewTests
//
//  The agent-facing safety gate: a visiting agent (over MCP) or M1K3's own local
//  model can ask the review panel to open a web page — but it must NOT be able to
//  point the embedded WebView at the user's local network (router admin pages,
//  localhost daemons, the 169.254.169.254 cloud-metadata address). Requests fire
//  from the user's Mac, so an un-gated open_link is an SSRF-lite surface. A USER
//  typing http://localhost:3000 is fine (handled at a different layer); this policy
//  guards only the automation paths.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-20, Confidence 0.85, Prior: Unknown

import Foundation
@testable import M1K3Preview
import Testing

struct WebURLPolicyTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    // MARK: - Public destinations are allowed

    @Test("ordinary public web URLs are not local/private")
    func publicAllowed() throws {
        #expect(try !WebURLPolicy.isLocalOrPrivate(url("https://example.com")))
        #expect(try !WebURLPolicy.isLocalOrPrivate(url("https://m1k3.app/docs")))
        #expect(try !WebURLPolicy.isLocalOrPrivate(url("http://93.184.216.34")))
        #expect(try !WebURLPolicy.isLocalOrPrivate(url("https://1.1.1.1")))
        #expect(try !WebURLPolicy.isLocalOrPrivate(url("https://8.8.8.8")))
    }

    // MARK: - Loopback / localhost

    @Test("loopback and localhost are local")
    func loopback() throws {
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://localhost:3000")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://127.0.0.1")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://127.5.6.7:8080")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://0.0.0.0")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://router.localhost")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://[::1]:8080")))
    }

    // MARK: - RFC 1918 private ranges

    @Test("private IPv4 ranges are local")
    func privateRanges() throws {
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://10.0.0.1")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://10.255.255.255")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://192.168.1.1")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://172.16.0.1")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://172.31.255.255")))
    }

    @Test("172.16/12 boundaries are respected — .15 and .32 are public")
    func privateRangeBoundaries() throws {
        #expect(try !WebURLPolicy.isLocalOrPrivate(url("http://172.15.0.1")))
        #expect(try !WebURLPolicy.isLocalOrPrivate(url("http://172.32.0.1")))
        // A public address that merely starts with "17" must not be caught.
        #expect(try !WebURLPolicy.isLocalOrPrivate(url("http://17.0.0.1")))
    }

    // MARK: - Link-local (incl. cloud metadata) + mDNS

    @Test("link-local 169.254/16 (cloud metadata) is local")
    func linkLocal() throws {
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://169.254.169.254")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://169.254.0.1")))
    }

    @Test(".local mDNS hostnames are local")
    func mdns() throws {
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://my-mac.local")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://printer.local:631")))
    }

    @Test("IPv6 link-local and unique-local are local")
    func ipv6Private() throws {
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://[fe80::1]")))
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://[fd00::1]")))
    }

    // MARK: - Obfuscated IPv4 literals (the resolver still routes these to loopback)

    @Test("obfuscated IPv4 literals (decimal/octal/hex/abbreviated/trailing-dot) are local")
    func obfuscatedIPv4() throws {
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://2130706433"))) // 127.0.0.1 as a 32-bit int
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://0177.0.0.1"))) // octal 0177 = 127
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://0x7f.0.0.1"))) // hex 0x7f = 127
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://127.1"))) // abbreviated a.d
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://127.0.0.1."))) // trailing FQDN dot
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://2852039166"))) // 169.254.169.254 metadata as int
        #expect(try WebURLPolicy.isLocalOrPrivate(url("http://0xA9FEA9FE"))) // 169.254.169.254 as a hex int
    }

    @Test("a public IP in non-canonical form is still allowed (no over-blocking)")
    func obfuscatedPublicAllowed() throws {
        #expect(try !WebURLPolicy.isLocalOrPrivate(url("http://1.1.1.1."))) // trailing dot, public
        #expect(try !WebURLPolicy.isLocalOrPrivate(url("http://example.com.")))
    }

    // MARK: - Defensive

    // MARK: - Resolved addresses (#210)

    @Test("a resolved address literal is judged like a host: IPv4-mapped, zone-scoped, full IPv6")
    func resolvedAddressLiterals() {
        #expect(WebURLPolicy.isPrivateAddress("10.0.0.1"))
        #expect(WebURLPolicy.isPrivateAddress("169.254.169.254"))
        #expect(WebURLPolicy.isPrivateAddress("::ffff:127.0.0.1")) // IPv4-mapped loopback
        #expect(WebURLPolicy.isPrivateAddress("::ffff:192.168.1.1"))
        #expect(WebURLPolicy.isPrivateAddress("fe80::1%en0")) // zone id stripped
        #expect(WebURLPolicy.isPrivateAddress("fd12:3456::1"))
        #expect(!WebURLPolicy.isPrivateAddress("93.184.216.34"))
        #expect(!WebURLPolicy.isPrivateAddress("::ffff:93.184.216.34"))
        #expect(!WebURLPolicy.isPrivateAddress("2606:4700:4700::1111"))
        #expect(!WebURLPolicy.isPrivateAddress("")) // nothing to judge — the fetch fails on its own
    }

    private struct FakeResolver: HostResolving {
        let table: [String: [String]]
        func addresses(for host: String) async -> [String]? {
            table[host] ?? []
        }
    }

    @Test("a public name that resolves into private space is refused — the DNS SSRF hole")
    func resolvedPrivateRefused() async throws {
        let resolver = FakeResolver(table: [
            "metadata.example.com": ["169.254.169.254"],
            "mixed.example.com": ["93.184.216.34", "10.1.2.3"],
            "public.example.com": ["93.184.216.34", "2606:4700::1"],
        ])
        #expect(try await WebURLPolicy.isLocalOrPrivate(url("https://metadata.example.com/x"), resolver: resolver))
        // ANY private answer refuses — a rotating record must not slip through on the public one.
        #expect(try await WebURLPolicy.isLocalOrPrivate(url("https://mixed.example.com"), resolver: resolver))
        #expect(try await !WebURLPolicy.isLocalOrPrivate(url("https://public.example.com"), resolver: resolver))
    }

    @Test("a literal host never consults the resolver; an unresolvable name is left to the fetch")
    func resolverScope() async throws {
        let resolver = FakeResolver(table: [:])
        // The literal check already decided; no DNS needed either way.
        #expect(try await WebURLPolicy.isLocalOrPrivate(url("http://127.0.0.1"), resolver: resolver))
        #expect(try await !WebURLPolicy.isLocalOrPrivate(url("https://1.1.1.1"), resolver: resolver))
        // No answer: not our verdict to give — the connection fails with its own error.
        #expect(try await !WebURLPolicy.isLocalOrPrivate(url("https://nope.example.com"), resolver: resolver))
    }

    private struct FailingResolver: HostResolving {
        func addresses(for _: String) async -> [String]? {
            nil
        }
    }

    @Test("a lookup that FAILS (error, timeout) refuses — the gate never saw the answer")
    func lookupFailureRefuses() async throws {
        #expect(try await WebURLPolicy.isLocalOrPrivate(url("https://slow.example.com"), resolver: FailingResolver()))
        // Literals still never ask.
        #expect(try await !WebURLPolicy.isLocalOrPrivate(url("https://1.1.1.1"), resolver: FailingResolver()))
    }

    @Test("the whole fe80::/10 block is link-local, not just fe80:")
    func linkLocalIPv6Block() {
        #expect(WebURLPolicy.isPrivateAddress("fe90::1"))
        #expect(WebURLPolicy.isPrivateAddress("febf::1"))
        #expect(!WebURLPolicy.isPrivateAddress("fec0::1")) // site-local (deprecated), outside /10
    }

    @Test("a slow system lookup is a failed lookup, not a stalled turn")
    func systemResolverTimesOut() async {
        // A name under an unroutable TLD is on no hosts file; with a near-zero
        // budget the race is decided by the sleep, never the lookup.
        let answers = await SystemHostResolver(timeout: 0.001).addresses(for: "gate-timeout-probe.invalid")
        #expect(answers == nil)
    }

    @Test("the system resolver answers for localhost with a loopback literal (live smoke)")
    func systemResolverSmoke() async {
        let answers = await SystemHostResolver().addresses(for: "localhost") ?? []
        #expect(!answers.isEmpty)
        #expect(answers.allSatisfy(WebURLPolicy.isPrivateAddress))
    }

    @Test("a URL with no host is treated as local (refused)")
    func noHostIsLocal() throws {
        // file:// has no host; defensively the policy refuses rather than allows.
        #expect(try WebURLPolicy.isLocalOrPrivate(url("file:///tmp/x")))
    }
}
