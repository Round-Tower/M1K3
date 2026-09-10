//
//  WebURLPolicy.swift
//  M1K3Preview
//
//  The agent-facing safety gate for open_link. A visiting agent (over MCP) or
//  M1K3's own local model can surface a web page into the review panel — but it
//  must not be able to aim the embedded WebView at the user's local network: the
//  fetch fires from the user's Mac, so an un-gated open_link would let an opaque
//  automation surface poke router admin pages, localhost daemons, or the
//  169.254.169.254 cloud-metadata address (classic SSRF-lite).
//
//  This guards ONLY the automation paths. A USER typing http://localhost:3000 into
//  the address bar to review their own dev server is legitimate and is routed by
//  ReviewTargetResolver without this gate.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-20, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.85 — #210: the gate now RESOLVES a
//  hostname (`HostResolving` seam, `SystemHostResolver` = getaddrinfo) and refuses when ANY
//  answer lands in private/link-local/loopback space; `isPrivateAddress` judges a resolved literal
//  (IPv4-mapped IPv6 and zone ids included). The literal-host check is unchanged and still pure.
//  A failed or slow lookup (4 s) refuses — the gate must SEE the answer. fe80::/10 matched fully.
//  Known remainder: resolve-then-connect is a TOCTOU window (DNS rebinding) — closing it means
//  pinning the connection to the vetted address, which URLSession does not offer.

import Foundation
#if canImport(Darwin)
    import Darwin
#endif

/// Name → addresses, for the resolved half of the gate. Empty means "no such
/// host" — the policy leaves that to the fetch's own error. nil means the
/// lookup itself FAILED (resolver error, timeout): the gate never got to see
/// what URLSession's own lookup would find, so the policy refuses.
public protocol HostResolving: Sendable {
    func addresses(for host: String) async -> [String]?
}

/// The system resolver (getaddrinfo, any family), numeric answers only. Runs
/// off the caller's executor — getaddrinfo blocks and has no cancellation, so
/// the lookup is raced against `timeout`; a name that resolves slower than
/// that is a failed lookup (nil), never a stalled turn (Stop must keep working).
public struct SystemHostResolver: HostResolving {
    public static let defaultTimeout: TimeInterval = 4
    private let timeout: TimeInterval
    /// The blocking lookup — the system's by default; a test injects a slow one.
    private let lookup: @Sendable (String) -> [String]?

    public init(timeout: TimeInterval = defaultTimeout) {
        self.init(timeout: timeout, lookup: Self.resolve)
    }

    init(timeout: TimeInterval, lookup: @escaping @Sendable (String) -> [String]?) {
        self.timeout = timeout
        self.lookup = lookup
    }

    /// First past the post: the lookup and a timer each run on their OWN
    /// unstructured task and race to resume one continuation. A task group
    /// would not do — it joins every child before returning, and getaddrinfo
    /// has no cancellation point, so the "loser" would still hold the caller
    /// (#266 review). The abandoned lookup finishes later and its answer is
    /// genuinely discarded.
    public func addresses(for host: String) async -> [String]? {
        let seconds = timeout
        let lookup = lookup
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
            let gate = FirstResume(continuation)
            Task.detached(priority: .utility) { gate.resume(with: lookup(host)) }
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                gate.resume(with: nil)
            }
        }
    }

    /// Resumes a continuation at most once, from whichever racer arrives first.
    private final class FirstResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String]?, Never>?

        init(_ continuation: CheckedContinuation<[String]?, Never>) {
            self.continuation = continuation
        }

        func resume(with answer: [String]?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: answer)
        }
    }

    #if canImport(Darwin)
        /// `[]` for EAI_NONAME (no such host), nil for any other failure.
        private static func resolve(_ host: String) -> [String]? {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &list)
            guard status == 0, let first = list else {
                return status == EAI_NONAME || status == EAI_NODATA ? [] : nil
            }
            defer { freeaddrinfo(first) }
            var found: [String] = []
            var node: UnsafeMutablePointer<addrinfo>? = first
            while let current = node {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    current.pointee.ai_addr, current.pointee.ai_addrlen,
                    &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
                ) == 0 {
                    found.append(String(cString: buffer))
                }
                node = current.pointee.ai_next
            }
            return found
        }
    #else
        private static func resolve(_: String) -> [String]? {
            nil
        }
    #endif
}

public enum WebURLPolicy {
    /// The full gate: the literal/host check first (pure, decides on its own for
    /// an IP literal, localhost, `.local`), then — for a DNS name — every
    /// address it resolves to must be public. Any private answer refuses: a
    /// record that rotates a public and a private address is the rebinding
    /// shape, and the fetch would take whichever came up (#210).
    public static func isLocalOrPrivate(_ url: URL, resolver: any HostResolving) async -> Bool {
        if isLocalOrPrivate(url) { return true }
        guard let host = normalisedHost(url), numericIPv4(host) == nil, !looksLikeIPv6(host) else {
            return false // a literal was judged above; nothing to resolve
        }
        guard let answers = await resolver.addresses(for: host) else { return true } // lookup failed: refuse
        return answers.contains(where: isPrivateAddress)
    }

    /// Judge one resolved address literal (what getaddrinfo hands back): IPv4,
    /// IPv6 (zone id `%en0` ignored), and IPv4-mapped IPv6 `::ffff:a.b.c.d`
    /// judged as the IPv4 it wraps. Empty is not private (nothing to judge).
    public static func isPrivateAddress(_ address: String) -> Bool {
        var literal = address.lowercased()
        if let zone = literal.firstIndex(of: "%") { literal = String(literal[..<zone]) }
        guard !literal.isEmpty else { return false }
        if literal.hasPrefix("::ffff:"), let ipv4 = numericIPv4(String(literal.dropFirst(7))) {
            return isPrivateIPv4(ipv4)
        }
        if let ipv4 = numericIPv4(literal) { return isPrivateIPv4(ipv4) }
        return isPrivateIPv6(literal)
    }

    /// Lowercased host with the DNS-root trailing dot(s) stripped — "127.0.0.1."
    /// and "printer.local." gate exactly like their bare forms. nil = no host.
    private static func normalisedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") {
            host = String(host.dropLast())
        }
        return host.isEmpty ? nil : host
    }

    private static func looksLikeIPv6(_ host: String) -> Bool {
        host.contains(":")
    }

    /// True when `url`'s host is loopback, an RFC 1918 private range, link-local
    /// (incl. cloud metadata), an mDNS `.local` name, or an IPv6 link/unique-local
    /// address — i.e. somewhere an agent-driven open must NOT reach. A missing host
    /// is treated as local (refused) so the default is safe.
    public static func isLocalOrPrivate(_ url: URL) -> Bool {
        guard let host = normalisedHost(url) else { return true }

        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasSuffix(".local") { return true }

        if let ipv4 = numericIPv4(host) {
            return isPrivateIPv4(ipv4)
        }
        return isPrivateIPv6(host)
    }

    // MARK: - IPv4

    /// Parse `host` as an IPv4 literal with the SAME classic BSD semantics the
    /// system resolver applies when the WebView loads the URL: decimal, octal
    /// (leading 0) and hex (0x) parts, plus the abbreviated forms `a`, `a.b`,
    /// `a.b.c`, `a.b.c.d`. Returns the 32-bit host-order address, or nil when it
    /// isn't a numeric IPv4 literal. Using `inet_aton` (not a strict dotted-quad
    /// parser) is what closes the 2130706433 / 0177.0.0.1 / 0x7f.1 / 127.1
    /// bypasses — the old parser waved those through as "not an IP" while the
    /// resolver still routed them to loopback.
    private static func numericIPv4(_ host: String) -> UInt32? {
        #if canImport(Darwin)
            var addr = in_addr()
            guard host.withCString({ inet_aton($0, &addr) }) == 1 else { return nil }
            return UInt32(bigEndian: addr.s_addr)
        #else
            return nil
        #endif
    }

    private static func isPrivateIPv4(_ ip: UInt32) -> Bool {
        let a = (ip >> 24) & 0xFF
        let b = (ip >> 16) & 0xFF
        switch (a, b) {
        case (0, _): return true // 0.0.0.0/8 (incl. 0.0.0.0)
        case (10, _): return true // 10.0.0.0/8
        case (127, _): return true // loopback 127.0.0.0/8
        case (169, 254): return true // link-local 169.254.0.0/16 (cloud metadata)
        case (172, 16 ... 31): return true // 172.16.0.0/12
        case (192, 168): return true // 192.168.0.0/16
        default: return false
        }
    }

    // MARK: - IPv6

    private static func isPrivateIPv6(_ host: String) -> Bool {
        if host == "::1" || host == "::" { return true } // loopback / unspecified
        // Link-local fe80::/10 (fe8., fe9., fea., feb.) and unique-local fc00::/7 (fc.. / fd..).
        return host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
            || host.hasPrefix("fc") || host.hasPrefix("fd")
    }
}
