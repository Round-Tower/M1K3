//
//  PairingPayload.swift
//  M1K3BrainLink
//
//  The QR payload both ends of the Brain at Home ceremony agree on
//  (BRAIN_AT_HOME_SPEC §4):
//
//    m1k3-pair://v1?psk=<b64url 32B>&id=<opaque>&port=<pairing port>
//        &mainPort=<serve port>&name=<mac name>&hosts=<addr,addr,…>
//
//  `hosts` is Phase C's addition — the Mac's private LAN addresses, because
//  the QR is the ONLY channel a first-time device has (the Bonjour advertiser
//  only runs once a paired device exists, so discovery can't help the first
//  pairing). Parse tolerates its absence (a pre-Phase-C QR still parses; the
//  UI asks for an address instead). Parse is strict about the secret — b64url
//  decoding to EXACTLY 32 bytes — and about the pairing port; presentation
//  fields default instead of failing.
//
//  Pure and Foundation-only, so both the Mac's compose and the device's parse
//  are pinned by the same round-trip tests.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.9 (pure, TDD'd
//  red-first; the wire shape is the server's 2026-08-19 inline compose,
//  lifted verbatim then extended with hosts).
//  Prior: BrainServeController.swift (inline compose, Kev + claude-fable-5).
//

import Foundation

public struct PairingPayload: Sendable, Equatable {
    /// The candidate secret — exactly 32 bytes.
    public let psk: Data
    /// The opaque PSK identity (spec S1: random, never a device name).
    public let identity: String
    /// The ephemeral pairing listener's port (serves only /v1/pair, ≤60 s).
    public let pairingPort: UInt16
    /// The main serve port the device talks to after Approve.
    public let mainPort: UInt16
    /// The Mac's display name, for the pairing UI.
    public let macName: String
    /// The Mac's private LAN addresses (IPv4 dotted / IPv6, may carry a zone
    /// suffix). Empty when the QR predates the hosts param.
    public let hosts: [String]

    public static let scheme = "m1k3-pair"
    public static let version = "v1"
    /// The well-known default serve port (BrainServeController.defaultPort).
    public static let defaultMainPort: UInt16 = 4243
    public static let keyLength = 32

    public init(
        psk: Data, identity: String, pairingPort: UInt16, mainPort: UInt16,
        macName: String, hosts: [String]
    ) {
        self.psk = psk
        self.identity = identity
        self.pairingPort = pairingPort
        self.mainPort = mainPort
        self.macName = macName
        self.hosts = hosts
    }

    /// The TLS-PSK credential this payload authorises.
    public var credential: PSKCredential {
        PSKCredential(identity: identity, key: psk)
    }

    // MARK: - Compose (the Mac's side)

    public func composed() -> String {
        var parts = [
            "psk=\(Self.base64URL(psk))",
            "id=\(identity)",
            "port=\(pairingPort)",
            "mainPort=\(mainPort)",
            "name=\(Self.percentEncode(macName))",
        ]
        if !hosts.isEmpty {
            parts.append("hosts=\(hosts.map(Self.percentEncode).joined(separator: ","))")
        }
        return "\(Self.scheme)://\(Self.version)?\(parts.joined(separator: "&"))"
    }

    // MARK: - Parse (the device's side)

    /// nil for anything that isn't a well-formed v1 payload carrying a
    /// 32-byte secret, an identity, and a pairing port. Never guesses at a
    /// secret; happily defaults the presentation fields.
    public static func parse(_ string: String) -> PairingPayload? {
        guard let components = URLComponents(string: string),
              components.scheme == scheme,
              components.host == version
        else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        guard let rawPSK = query["psk"], let key = decodeBase64URL(rawPSK),
              key.count == keyLength,
              let identity = query["id"], !identity.isEmpty,
              let rawPort = query["port"], let port = UInt16(rawPort), port > 0
        else { return nil }
        let mainPort = query["mainPort"].flatMap(UInt16.init).flatMap { $0 > 0 ? $0 : nil }
            ?? defaultMainPort
        let name = query["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "M1K3"
        // URLComponents already percent-decoded values; hosts re-split on ","
        // (the separator is never legal inside an address).
        let hosts = (query["hosts"] ?? "")
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty }
        return PairingPayload(
            psk: key, identity: identity, pairingPort: port,
            mainPort: mainPort, macName: name, hosts: hosts
        )
    }

    // MARK: - Encoding helpers

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 {
            normalized.append("=")
        }
        return Data(base64Encoded: normalized)
    }

    private static func percentEncode(_ value: String) -> String {
        // Query-safe minus the characters this payload uses structurally
        // (&, =, +, comma) — so a name or zone id can't split params.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+,")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
