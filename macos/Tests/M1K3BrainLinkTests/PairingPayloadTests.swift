//
//  PairingPayloadTests.swift
//  M1K3BrainLinkTests
//
//  The QR payload both ends must agree on. Compose is the Mac's side of the
//  ceremony, parse is the device's — the round-trip test IS the contract.
//  Parse is strict about the secret (exactly 32 bytes of b64url) and lenient
//  about presentation fields (name defaults, hosts optional for pre-Phase-C
//  QRs that carried no address).
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.9 (pure, TDD'd
//  red-first). Prior: BrainServeController.swift's inline compose (2026-08-19).
//

import Foundation
import M1K3BrainLink
import Testing

struct PairingPayloadTests {
    private let key = Data((0 ..< 32).map { UInt8($0) })

    private func payload(hosts: [String] = ["192.168.1.24"]) -> PairingPayload {
        PairingPayload(
            psk: key,
            identity: "9D9A44E6-27E4-4E86-B7C0-4E2E0AB2E9AD",
            pairingPort: 52113,
            mainPort: 4243,
            macName: "Kev’s Mac Studio",
            hosts: hosts
        )
    }

    @Test func roundTripsThroughComposeAndParse() {
        let composed = payload().composed()
        let parsed = PairingPayload.parse(composed)
        #expect(parsed == payload())
    }

    @Test func roundTripsAnIPv6HostWithZone() {
        let hosts = ["fe80::1c2a:ff:fe4e:1%en0", "192.168.1.24"]
        let parsed = PairingPayload.parse(payload(hosts: hosts).composed())
        #expect(parsed?.hosts == hosts)
    }

    @Test func parsesTheServersPreHostsShape() {
        // The 2026-08-19 Mac composed exactly this — no hosts param. It must
        // still parse (hosts empty; the UI falls back to asking for an address).
        let psk = key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let legacy = "m1k3-pair://v1?psk=\(psk)&id=ABC-123&port=50000&mainPort=4243&name=M1K3"
        let parsed = PairingPayload.parse(legacy)
        #expect(parsed?.identity == "ABC-123")
        #expect(parsed?.psk == key)
        #expect(parsed?.pairingPort == 50000)
        #expect(parsed?.mainPort == 4243)
        #expect(parsed?.hosts.isEmpty == true)
    }

    @Test func percentEncodedNameDecodes() {
        let parsed = PairingPayload.parse(payload().composed())
        #expect(parsed?.macName == "Kev’s Mac Studio")
    }

    @Test func rejectsWrongScheme() {
        let mangled = payload().composed().replacingOccurrences(of: "m1k3-pair://", with: "https://")
        #expect(PairingPayload.parse(mangled) == nil)
    }

    @Test func rejectsWrongVersion() {
        let mangled = payload().composed().replacingOccurrences(of: "://v1?", with: "://v2?")
        #expect(PairingPayload.parse(mangled) == nil)
    }

    @Test func rejectsAMissingSecret() {
        #expect(PairingPayload.parse("m1k3-pair://v1?id=ABC&port=50000") == nil)
    }

    @Test func rejectsASecretThatIsNot32Bytes() {
        let short = Data([1, 2, 3]).base64EncodedString()
        #expect(PairingPayload.parse("m1k3-pair://v1?psk=\(short)&id=ABC&port=50000") == nil)
    }

    @Test func rejectsJunkBase64() {
        #expect(PairingPayload.parse("m1k3-pair://v1?psk=!!!!&id=ABC&port=50000") == nil)
    }

    @Test func rejectsAMissingIdentity() {
        let psk = key.base64EncodedString()
        #expect(PairingPayload.parse("m1k3-pair://v1?psk=\(psk)&port=50000") == nil)
    }

    @Test func rejectsAnUnparseablePort() {
        let psk = key.base64EncodedString()
        #expect(PairingPayload.parse("m1k3-pair://v1?psk=\(psk)&id=ABC&port=99999999") == nil)
        #expect(PairingPayload.parse("m1k3-pair://v1?psk=\(psk)&id=ABC&port=0") == nil)
        #expect(PairingPayload.parse("m1k3-pair://v1?psk=\(psk)&id=ABC") == nil)
    }

    @Test func missingMainPortDefaultsToTheWellKnownServePort() {
        let psk = key.base64EncodedString()
        let parsed = PairingPayload.parse("m1k3-pair://v1?psk=\(psk)&id=ABC&port=50000")
        #expect(parsed?.mainPort == 4243)
    }

    @Test func missingNameDefaultsToM1K3() {
        let psk = key.base64EncodedString()
        let parsed = PairingPayload.parse("m1k3-pair://v1?psk=\(psk)&id=ABC&port=50000")
        #expect(parsed?.macName == "M1K3")
    }

    @Test func composeEmitsBase64URLWithoutPadding() {
        // The psk param value must be URL-safe base64: no +, /, or padding.
        let composed = payload().composed()
        let psk = composed
            .components(separatedBy: "psk=").dropFirst().first?
            .components(separatedBy: "&").first ?? ""
        #expect(!psk.isEmpty)
        #expect(psk.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func credentialCarriesTheIdentityAndKey() {
        let credential = payload().credential
        #expect(credential.identity == payload().identity)
        #expect(credential.key == key)
    }
}
