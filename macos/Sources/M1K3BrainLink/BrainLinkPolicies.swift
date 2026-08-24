//
//  BrainLinkPolicies.swift
//  M1K3BrainLink
//
//  The pure decision layers around the client wire: which of the Mac's
//  addresses belong in a pairing QR (the Mac composes; the device dials),
//  and the client's readings of health, 429-refusal, and pair responses.
//
//  Address rules, and why: the QR is a first-contact channel — Bonjour can't
//  help before the first pairing (the advertiser only runs once a device is
//  paired), so the QR must carry dialable addresses. Loopback and link-local
//  are dropped (meaningless or zone-bound off-machine); tunnel/AirDrop-class
//  interfaces are dropped because the listener itself prohibits them
//  (`prohibitedInterfaceTypes = [.cellular, .other]`) — advertising an
//  address the listener won't accept on would be a lie.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.9 (pure, TDD'd
//  red-first; refusal/health shapes pinned against the server's encoders).
//  Prior: Unknown.
//

import Foundation

// MARK: - LAN addresses (the Mac's side of the QR)

public enum LANAddresses {
    /// Interface-name prefixes that never carry a reachable serve address:
    /// loopback, tunnels (the listener prohibits `.other`-class interfaces),
    /// AirDrop/AWDL, and the low-latency WLAN interface.
    static let excludedInterfacePrefixes = ["lo", "utun", "awdl", "llw", "gif", "stf", "pktap"]

    /// Pure filter over (interface, address) candidates: private unicast
    /// addresses a remote device could actually dial. IPv4 first (the robust
    /// path), unique-local IPv6 after; loopback, link-local (both families),
    /// and public addresses are dropped. Order otherwise preserved; dupes
    /// collapse.
    public static func servable(from candidates: [(interface: String, address: String)]) -> [String] {
        var ipv4: [String] = []
        var ipv6: [String] = []
        for candidate in candidates {
            let name = candidate.interface.lowercased()
            guard !excludedInterfacePrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let address = candidate.address
            let bare = address.split(separator: "%").first.map(String.init) ?? address
            if isPrivateUnicastIPv4(bare) {
                if !ipv4.contains(bare) { ipv4.append(bare) }
            } else if isUniqueLocalIPv6(bare) {
                if !ipv6.contains(bare) { ipv6.append(bare) }
            }
        }
        return ipv4 + ipv6
    }

    private static func isPrivateUnicastIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        if octets[0] == 127 { return false } // loopback — not dialable remotely
        if octets[0] == 169, octets[1] == 254 { return false } // link-local
        if octets[0] == 10 { return true }
        if octets[0] == 172, (16 ... 31).contains(octets[1]) { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        return false
    }

    private static func isUniqueLocalIPv6(_ address: String) -> Bool {
        let lower = address.lowercased()
        guard lower.contains(":") else { return false }
        // fe80 link-local is zone-bound to the MAC's interface name — useless
        // on another device. Only unique-local (fc00::/7) travels.
        return lower.hasPrefix("fd") || lower.hasPrefix("fc")
    }
}

// MARK: - Health

/// The /v1/health body — BrainServeController.healthJSON()'s shape.
public struct BrainHealth: Sendable, Equatable {
    public let ok: Bool
    public let brain: String
    public let ready: Bool

    public init(ok: Bool, brain: String, ready: Bool) {
        self.ok = ok
        self.brain = brain
        self.ready = ready
    }

    public static func parse(_ body: Data?) -> BrainHealth? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let ok = json["ok"] as? Bool
        else { return nil }
        return BrainHealth(
            ok: ok,
            brain: json["brain"] as? String ?? "",
            ready: json["ready"] as? Bool ?? false
        )
    }
}

// MARK: - 429 refusals

/// A 429 from the Mac, decoded into the etiquette vocabulary the server
/// speaks (busy local turn / thermal cooling / brain warming) with the
/// friendly copy the client UI shows.
public struct BrainRefusal: Sendable, Equatable {
    public enum Reason: String, Sendable {
        case busy
        case cooling
        case warming
    }

    public let reason: Reason
    public let retryAfterSeconds: Int

    public init(reason: Reason, retryAfterSeconds: Int) {
        self.reason = reason
        self.retryAfterSeconds = retryAfterSeconds
    }

    /// nil unless this is a 429; unknown reason strings read as .busy (the
    /// safest retry posture).
    public static func parse(status: Int, body: Data?, retryAfterHeader: Int?) -> BrainRefusal? {
        guard status == 429 else { return nil }
        var reason = Reason.busy
        var seconds = retryAfterHeader ?? 15
        if let body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        {
            if let raw = json["error"] as? String, let parsed = Reason(rawValue: raw) {
                reason = parsed
            }
            if let bodySeconds = json["retry_after_s"] as? Int {
                seconds = bodySeconds
            }
        }
        return BrainRefusal(reason: reason, retryAfterSeconds: seconds)
    }

    public var userMessage: String {
        switch reason {
        case .busy:
            "Your Mac is in the middle of its own turn — try again in a moment."
        case .cooling:
            "Your Mac is running warm and resting its brain — try again shortly."
        case .warming:
            "Your Mac's brain is still warming up — try again in a moment."
        }
    }
}

// MARK: - Pair response

public enum PairResponse: Sendable, Equatable {
    case pendingApproval
    case rejected(String)

    public static func parse(_ body: Data?) -> PairResponse {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return .rejected("The Mac sent an unreadable pairing reply.") }
        if json["status"] as? String == "pending-approval" { return .pendingApproval }
        if let message = json["error"] as? String { return .rejected(message) }
        return .rejected("The Mac sent an unexpected pairing reply.")
    }
}

public extension LANAddresses {
    /// The Mac's current servable addresses, for the pairing QR — getifaddrs
    /// enumerated, then the pure `servable` filter. Effectful but read-only.
    static func current() -> [String] {
        var addresses: [(interface: String, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let addressPointer = interface.pointee.ifa_addr else { continue }
            let family = addressPointer.pointee.sa_family
            guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = family == sa_family_t(AF_INET)
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(
                addressPointer, length, &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            addresses.append((interface: name, address: String(cString: host)))
        }
        return servable(from: addresses)
    }
}
