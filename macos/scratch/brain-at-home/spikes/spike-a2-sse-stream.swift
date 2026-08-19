//
//  spike-a2-sse-stream.swift — Brain-at-Home Phase A, spike A2
//
//  QUESTION: can we stream token-by-token over the PSK channel — a chunked
//  SSE-style server WRITE the client reads INCREMENTALLY (not buffered until
//  close), with client cancellation reaching the server mid-stream? The repo
//  has zero streaming HTTP (HTTPWireCodec is buffered Content-Length +
//  Connection: close), so both halves are net-new.
//
//  Also answers: can URLSession be the client? (No — spelled out in
//  RESULTS.md: URLSession has no external-PSK hook, so the streaming client
//  must be NWConnection on both Apple platforms.)
//
//  Run: swift spike-a2-sse-stream.swift   (exit 0 = all criteria pass)
//
//  Criteria:
//   1. events arrive INCREMENTALLY (≥3 distinct arrival timestamps spread
//      over the send cadence — proof nothing coalesced them into one close)
//   2. the client can CANCEL mid-stream and the server's next send FAILS
//      (cancellation propagates; no zombie generation)
//   3. all of it over the A1 ECDHE_PSK channel (encrypted streaming)
//
//  Signed: Kev + claude-fable-5, 2026-08-19 (scratch spike — no production
//  code; verdict in RESULTS.md). Prior: spike-a1-tls-psk.swift.
//

import Foundation
import Network
import Security

let pskBytes = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
let identity = "m1k3-spike-a2"
var failures = 0
func report(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

/// The A1-proven arm: TLS 1.2 + TLS_ECDHE_PSK_WITH_AES_128_GCM_SHA256.
func pskTLSOptions() -> NWProtocolTLS.Options {
    let options = NWProtocolTLS.Options()
    let sec = options.securityProtocolOptions
    pskBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let pskDD = DispatchData(bytes: raw)
        Data(identity.utf8).withUnsafeBytes { (iraw: UnsafeRawBufferPointer) in
            let idDD = DispatchData(bytes: iraw)
            sec_protocol_options_add_pre_shared_key(sec, pskDD as __DispatchData, idDD as __DispatchData)
        }
    }
    sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: 0xD001)!)
    sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
    return options
}

let serverQueue = DispatchQueue(label: "spike.a2.server")
let eventCount = 6
let sendInterval: TimeInterval = 0.15

/// Tracks whether a server send failed after the client cancelled.
/// `@unchecked Sendable`: the only mutable state is `_failedAtEvent`, and
/// every access to it goes through `lock` — so the concurrency the compiler
/// can't verify here is upheld by that single lock (review-fold clarity note).
final class SendOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _failedAtEvent: Int?
    func markFailure(at event: Int) {
        lock.lock()
        defer { lock.unlock() } // defer everywhere, so a future branch stays safe
        if _failedAtEvent == nil { _failedAtEvent = event }
    }

    var failedAtEvent: Int? {
        lock.lock()
        defer { lock.unlock() }
        return _failedAtEvent
    }
}

let sendOutcome = SendOutcome()
let serverDone = DispatchSemaphore(value: 0)

let params = NWParameters(tls: pskTLSOptions())
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 0)
let listener = try! NWListener(using: params)
listener.newConnectionHandler = { connection in
    connection.start(queue: serverQueue)
    // SSE-style: head first, then events on a cadence — each send flushed
    // individually (no Content-Length; the stream IS the body).
    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n\r\n"
    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    func sendEvent(_ index: Int) {
        guard index < eventCount else {
            connection.send(
                content: Data("event: done\ndata: {}\n\n".utf8),
                completion: .contentProcessed { _ in serverDone.signal() }
            )
            return
        }
        let frame = "data: {\"token\":\"tok-\(index)\"}\n\n"
        connection.send(content: Data(frame.utf8), completion: .contentProcessed { error in
            if error != nil {
                // The client went away — this is criterion 2's signal.
                sendOutcome.markFailure(at: index)
                serverDone.signal()
                return
            }
            serverQueue.asyncAfter(deadline: .now() + sendInterval) { sendEvent(index + 1) }
        })
    }
    sendEvent(0)
}

let ready = DispatchSemaphore(value: 0)
listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
listener.start(queue: serverQueue)
guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
    print("FAIL  listener never ready")
    exit(2)
}

print("SSE listener up on 127.0.0.1:\(port.rawValue) over ECDHE_PSK")

/// Client: read incrementally, record arrival times, optionally cancel after
/// `cancelAfterEvents` data frames.
func streamClient(cancelAfterEvents: Int?) -> (arrivals: [TimeInterval], text: String) {
    let connection = NWConnection(host: .ipv4(.loopback), port: port, using: NWParameters(tls: pskTLSOptions()))
    let queue = DispatchQueue(label: "spike.a2.client")
    let done = DispatchSemaphore(value: 0)
    let start = Date()
    var arrivals: [TimeInterval] = []
    var text = ""
    func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                arrivals.append(Date().timeIntervalSince(start))
                text += String(data: data, encoding: .utf8) ?? ""
                let events = text.components(separatedBy: "\n\n").count - 1
                if let cap = cancelAfterEvents, events >= cap {
                    connection.cancel() // mid-stream hangup — criterion 2
                    done.signal()
                    return
                }
                if text.contains("event: done") {
                    done.signal()
                    return
                }
            }
            if isComplete || error != nil {
                done.signal()
                return
            }
            receiveLoop()
        }
    }
    connection.stateUpdateHandler = { state in
        if case .ready = state { receiveLoop() }
        if case .failed = state { done.signal() }
    }
    connection.start(queue: queue)
    _ = done.wait(timeout: .now() + 10)
    connection.cancel()
    return (arrivals, text)
}

// Criterion 1 — incremental arrival across the full stream.
let full = streamClient(cancelAfterEvents: nil)
let spread = (full.arrivals.last ?? 0) - (full.arrivals.first ?? 0)
report(
    "events arrive incrementally",
    full.arrivals.count >= 3 && spread > sendInterval * 2,
    "\(full.arrivals.count) arrivals over \(String(format: "%.0f", spread * 1000))ms"
)
report("all events + done frame received", full.text.contains("tok-\(eventCount - 1)") && full.text.contains("event: done"))
_ = serverDone.wait(timeout: .now() + 5)

/// Criterion 2 — cancel mid-stream; the server's next send must fail.
let partial = streamClient(cancelAfterEvents: 2)
_ = serverDone.wait(timeout: .now() + 5)
report(
    "client cancel reaches the server mid-stream",
    sendOutcome.failedAtEvent != nil,
    sendOutcome.failedAtEvent.map { "server send failed at event \($0)" } ?? "server never saw the hangup"
)
report("cancelled client stopped early", !partial.text.contains("event: done"))

listener.cancel()
print(failures == 0 ? "\nA2 VERDICT: PASS (4/4)" : "\nA2 VERDICT: FAIL (\(failures) criteria failed)")
exit(failures == 0 ? 0 : 1)
