//
//  BrainServeTLS.swift
//  M1K3BrainServe
//
//  The TLS-PSK channel builder — the mechanism spike A1 proved
//  (scratch/brain-at-home/spikes/RESULTS.md): TLS 1.2 pinned (min = max) +
//  TLS_ECDHE_PSK_WITH_AES_128_GCM_SHA256 (RFC 8442, 0xD001) — PSK mutual
//  authentication WITH forward secrecy. TLS 1.3 external-PSK does NOT
//  handshake on Network.framework as of macOS 26.4 (-9838); revisit the
//  version pin per OS release — moving is a two-line change here.
//
//  The modern tls_ciphersuite_t enum carries no PSK cases (SDK-header
//  verified), so the suite arrives through the imported-C-enum raw-value
//  door. No other suites are appended: no-PSK, wrong-PSK, and plain-TCP
//  clients all hard-fail with zero application bytes (spike-proven).
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.85 (the mechanics
//  are a straight lift of the passing spike; multi-identity add is the one
//  part the spike ran with a single key — pinned by the listener tests).
//  Prior: spikes/spike-a1-tls-psk.swift.
//

import Foundation
import Network
import Security

/// One paired device's channel credential. The identity is the opaque label
/// TLS sends in the clear (audit S1 — never a device name); the key is the
/// 32-byte secret from the QR ceremony.
public struct PSKCredential: Sendable {
    public let identity: String
    public let key: Data

    public init(identity: String, key: Data) {
        self.identity = identity
        self.key = key
    }
}

public enum BrainServeTLS {
    /// RFC 8442 TLS_ECDHE_PSK_WITH_AES_128_GCM_SHA256.
    static let ecdhePSKSuite: UInt16 = 0xD001

    /// Options for a listener holding N paired credentials, or a client
    /// holding its one. The stack selects among identities from the
    /// ClientHello's cleartext identity field.
    public static func options(credentials: [PSKCredential]) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        for credential in credentials {
            credential.key.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let keyDD = DispatchData(bytes: raw)
                Data(credential.identity.utf8).withUnsafeBytes { (iraw: UnsafeRawBufferPointer) in
                    let idDD = DispatchData(bytes: iraw)
                    sec_protocol_options_add_pre_shared_key(sec, keyDD as __DispatchData, idDD as __DispatchData)
                }
            }
        }
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: ecdhePSKSuite)!
        )
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        return options
    }
}

/// Accept-time source gate (audit B3's second half): even with interface
/// types pinned, only private/link-local sources are served — an incidental
/// route (hotspot, tunnel that slipped the interface filter) can't widen the
/// boundary. Pure so it's test-pinned.
public enum PrivateSourcePolicy {
    public static func isPrivate(host: String) -> Bool {
        let bare = host.split(separator: "%").first.map(String.init) ?? host // strip zone id
        if bare == "127.0.0.1" || bare == "::1" || bare == "localhost" { return true }
        // IPv4-mapped IPv6 (::ffff:a.b.c.d — a dual-stack accept can render a
        // v4 peer this way): judge the EMBEDDED v4 address. Without this arm
        // the mapped form fell through to the IPv6 prefixes and was refused —
        // fail-closed, but it would refuse a legitimate LAN client.
        if bare.lowercased().hasPrefix("::ffff:") {
            return isPrivate(host: String(bare.dropFirst("::ffff:".count)))
        }
        // IPv4 private + link-local ranges.
        let octets = bare.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            if octets[0] == 10 { return true }
            if octets[0] == 172, (16 ... 31).contains(octets[1]) { return true }
            if octets[0] == 192, octets[1] == 168 { return true }
            if octets[0] == 169, octets[1] == 254 { return true }
            if octets[0] == 127 { return true }
            return false
        }
        // IPv6: link-local + unique-local only.
        let lower = bare.lowercased()
        if lower.hasPrefix("fe80:") { return true }
        if lower.hasPrefix("fd") || lower.hasPrefix("fc") { return true }
        return false
    }
}
