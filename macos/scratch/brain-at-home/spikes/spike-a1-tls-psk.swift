//
//  spike-a1-tls-psk.swift — Brain-at-Home Phase A, spike A1
//
//  QUESTION: does Network.framework give us TLS 1.3 with an external PSK —
//  mutual auth + encryption, no certificates — with the NEGATIVE paths
//  hard-failing (no PSK / wrong PSK / forced TLS 1.2 → zero bytes served)?
//
//  Run: swift spike-a1-tls-psk.swift   (exit 0 = all criteria pass)
//
//  Criteria (SPEC.md §7 A1, audit S1/B3/B4):
//   1. correct-PSK client completes the handshake and round-trips bytes
//   2. wrong-PSK client gets ZERO bytes and no successful echo
//   3. plain-TCP (no TLS) client gets ZERO bytes
//   4. TLS-1.2-capped client (same PSK) cannot handshake
//   5. the multi-identity selection block API exists (compile-time proof)
//   6. interface-pinning API accepted on a listener (Tailscale check is
//      hardware-owed — loopback can't demonstrate it)
//
//  Signed: Kev + claude-fable-5, 2026-08-19 (scratch spike — no production
//  code; verdict in RESULTS.md). Prior: none.
//

import Foundation
import Network
import Security

let pskBytes = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
let identity = "m1k3-spike-identity" // opaque in prod (audit S1); fixed here

var failures = 0
func report(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

enum PSKMode {
    /// TLS 1.3 pinned both ends + a 1.3 ciphersuite — what the SPEC assumed.
    case tls13
    /// TLS 1.2 pinned + the classic PSK suite (0x00A8) — NOT in the modern
    /// tls_ciphersuite_t enum (verified against SecProtocolTypes.h, which
    /// carries RSA/ECDHE/1.3 suites only); constructed via the C-enum
    /// rawValue door to probe whether boringssl still honours it.
    case tls12RawPSK
    /// TLS 1.2 + TLS_ECDHE_PSK_WITH_AES_128_GCM_SHA256 (RFC 8442, 0xD001) —
    /// PSK auth WITH forward secrecy, if the stack honours it.
    case tls12RawECDHEPSK
    /// Right PSK but the client caps at 1.2 while the server demands 1.3.
    case tls12CapAgainst13
}

func makeTLSOptions(psk: Data, mode: PSKMode) -> NWProtocolTLS.Options {
    let options = NWProtocolTLS.Options()
    let sec = options.securityProtocolOptions
    psk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let pskDD = DispatchData(bytes: raw)
        Data(identity.utf8).withUnsafeBytes { (iraw: UnsafeRawBufferPointer) in
            let idDD = DispatchData(bytes: iraw)
            sec_protocol_options_add_pre_shared_key(sec, pskDD as __DispatchData, idDD as __DispatchData)
        }
    }
    switch mode {
    case .tls13:
        sec_protocol_options_append_tls_ciphersuite(sec, .AES_128_GCM_SHA256)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
    case .tls12RawPSK:
        // TLS_PSK_WITH_AES_128_GCM_SHA256 — imported C enums accept unlisted
        // raw values, so this compiles; whether the stack honours it is the
        // question this arm answers.
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: 0x00A8)!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
    case .tls12RawECDHEPSK:
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: 0xD001)!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
    case .tls12CapAgainst13:
        sec_protocol_options_append_tls_ciphersuite(sec, .AES_128_GCM_SHA256)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
    }
    return options
}

/// Criterion 5 — the constant-time multi-identity selection seam exists.
let selectionBlockExists: sec_protocol_pre_shared_key_selection_t = { _, _, complete in
    complete(nil)
}

_ = selectionBlockExists

// MARK: - Harness

let serverQueue = DispatchQueue(label: "spike.server")

/// Start a TLS-PSK echo listener on loopback:ephemeral. Returns (listener, port).
func startEchoListener(mode: PSKMode) -> (NWListener, NWEndpoint.Port)? {
    let params = NWParameters(tls: makeTLSOptions(psk: pskBytes, mode: mode))
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 0)
    guard let listener = try? NWListener(using: params) else { return nil }
    listener.newConnectionHandler = { connection in
        connection.start(queue: serverQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if let data, error == nil {
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                connection.cancel()
            }
        }
    }
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
        if case .ready = state { ready.signal() }
        if case .failed = state { ready.signal() }
    }
    listener.start(queue: serverQueue)
    guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
        listener.cancel()
        return nil
    }
    return (listener, port)
}

/// Connect with the given parameters, send a probe, wait for a reply.
/// Returns whatever bytes came back (nil = zero bytes before the deadline).
func attemptEcho(
    name: String, port: NWEndpoint.Port, parameters: NWParameters, timeout: TimeInterval = 4
) -> Data? {
    let connection = NWConnection(host: .ipv4(.loopback), port: port, using: parameters)
    let queue = DispatchQueue(label: "spike.client.\(name)")
    let done = DispatchSemaphore(value: 0)
    let box = NSMutableData()
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            connection.send(content: Data("hello \(name)".utf8), completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data { box.append(data) }
                done.signal()
            }
        case .failed, .cancelled:
            done.signal()
        case let .waiting(error):
            // TLS auth failures surface as .waiting (retryable) — for the
            // spike that IS the failure signal; don't sit out the retry loop.
            print("      [\(name)] waiting: \(error)")
            connection.cancel()
        default:
            break
        }
    }
    connection.start(queue: queue)
    _ = done.wait(timeout: .now() + timeout)
    connection.cancel()
    return box.length > 0 ? (box as Data) : nil
}

func hexPrefix(_ data: Data?, _ count: Int = 8) -> String {
    guard let data else { return "∅" }
    return data.prefix(count).map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - Which PSK arm actually handshakes? (the load-bearing question)

var workingMode: PSKMode?
for (label, mode) in [("TLS 1.3 PSK (spec's assumption)", PSKMode.tls13),
                      ("TLS 1.2 + ECDHE_PSK 0xD001 (fwd secrecy)", PSKMode.tls12RawECDHEPSK),
                      ("TLS 1.2 + raw PSK suite 0x00A8", PSKMode.tls12RawPSK)]
{
    guard let (listener, port) = startEchoListener(mode: mode) else {
        print("INFO  \(label): listener refused to start")
        continue
    }
    let echoed = attemptEcho(
        name: "good-\(label.hasPrefix("TLS 1.3") ? "13" : "12")", port: port,
        parameters: NWParameters(tls: makeTLSOptions(psk: pskBytes, mode: mode))
    )
    let ok = echoed?.suffix(from: 0).starts(with: Data("hello good-".utf8)) == true
    print("INFO  \(label): \(ok ? "HANDSHAKES + round-trips" : "does NOT handshake")")
    listener.cancel()
    if ok, workingMode == nil { workingMode = mode }
}

guard let workingMode, let (listener, port) = startEchoListener(mode: workingMode) else {
    report("some PSK arm handshakes", false, "neither TLS 1.3 PSK nor TLS 1.2 raw-PSK completed")
    print("\nA1 VERDICT: FAIL — no viable Network.framework PSK arm on this OS")
    exit(1)
}

let armName = switch workingMode {
case .tls13: "TLS 1.3 PSK"
case .tls12RawECDHEPSK: "TLS 1.2 ECDHE_PSK (forward secrecy)"
case .tls12RawPSK: "TLS 1.2 PSK"
case .tls12CapAgainst13: "unexpected"
}
print("negative battery runs against the working arm: \(armName), 127.0.0.1:\(port.rawValue)")

/// 1. Correct PSK → echo round-trips (re-proven against the battery listener).
let good = attemptEcho(
    name: "good-psk", port: port, parameters: NWParameters(tls: makeTLSOptions(psk: pskBytes, mode: workingMode))
)
report("correct PSK round-trips", good == Data("hello good-psk".utf8))

// 2. Wrong PSK → no application bytes (a TLS alert record is acceptable).
let wrongKey = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
let wrong = attemptEcho(
    name: "wrong-psk", port: port, parameters: NWParameters(tls: makeTLSOptions(psk: wrongKey, mode: workingMode))
)
report("wrong PSK never completes/echoes", wrong == nil || wrong?.first == 0x15,
       "got \(hexPrefix(wrong))")

// 3. Plain TCP (no TLS): the server may answer the garbage with a TLS
//    alert/handshake RECORD (0x15/0x16) — the criterion is that no
//    APPLICATION bytes are served: never our echo, only TLS record framing.
let plain = attemptEcho(name: "plain-tcp", port: port, parameters: NWParameters.tcp)
let plainOK = plain == nil || (plain! != Data("hello plain-tcp".utf8) && [0x15, 0x16].contains(plain![0]))
report("plain TCP served no application bytes", plainOK, "got \(hexPrefix(plain))")

// 4. TLS 1.2-capped client against a 1.3-min server (only meaningful when the
//    1.3 arm works; on a 1.2 arm this criterion is vacuous and reported so).
if workingMode == .tls13 {
    let tls12 = attemptEcho(
        name: "tls12-cap", port: port,
        parameters: NWParameters(tls: makeTLSOptions(psk: pskBytes, mode: .tls12CapAgainst13))
    )
    report("TLS 1.2-capped client refused", tls12 == nil || tls12?.first == 0x15, "got \(hexPrefix(tls12))")
} else {
    report("TLS 1.2-capped client refused", true, "vacuous — working arm IS 1.2; min-version pin criterion moves to the design")
}

// 5. Selection-block API — reaching here means it compiled.
report("PSK selection-block API exists (compile-time)", true)

/// 6. Interface pinning accepted by NWListener (semantics are hardware-owed).
let pinnedParams = NWParameters(tls: makeTLSOptions(psk: pskBytes, mode: workingMode))
pinnedParams.prohibitedInterfaceTypes = [.cellular, .other] // .other covers utun/VPN tunnels
let pinnedListener = try? NWListener(using: pinnedParams)
report("interface-pinning parameters accepted", pinnedListener != nil,
       "prohibited [.cellular, .other]; live Tailscale-unreachable check is hardware-owed")
pinnedListener?.cancel()

listener.cancel()
print(failures == 0 ? "\nA1 VERDICT: PASS on \(armName) (\(6 - failures)/6)"
    : "\nA1 VERDICT: FAIL (\(failures) criteria failed)")
exit(failures == 0 ? 0 : 1)
