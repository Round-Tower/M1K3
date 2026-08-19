//
//  BrainServePolicies.swift
//  M1K3BrainServe
//
//  The pure request-side policies of the Brain at Home listener: route
//  classification, generate-request parsing, SSE frame encoding, and the
//  remote-turn admission decision (the person at the Mac outranks the person
//  on the sofa — SPEC §8a.3). All TDD-fast; the listener actor is the only
//  effectful shell.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.9 (pure, TDD'd).
//  Prior: scratch/brain-at-home/SPEC.md §3 + spikes/RESULTS.md.
//

import Foundation

// MARK: - Routes

/// Every route requires the PSK-authenticated channel (audit B4) — the TLS
/// layer enforces that before a byte of HTTP exists; this only classifies.
public enum BrainServeRoute: Sendable, Equatable {
    case generate
    case health
    case mcp
    case pair
    case notFound

    public static func classify(method: String, path: String) -> BrainServeRoute {
        switch (method.uppercased(), path) {
        case ("POST", "/v1/generate"): .generate
        case ("GET", "/v1/health"): .health
        case ("POST", "/mcp"): .mcp
        case ("POST", "/v1/pair"): .pair
        default: .notFound
        }
    }
}

// MARK: - Generate request

public struct GenerateRequest: Sendable, Equatable {
    public let prompt: String
    public let maxTokens: Int?

    public init(prompt: String, maxTokens: Int?) {
        self.prompt = prompt
        self.maxTokens = maxTokens
    }

    /// Parse a request body. Nil for junk JSON or a missing/blank prompt —
    /// the caller answers 400, never guesses.
    public static func parse(_ body: Data?) -> GenerateRequest? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let prompt = (json["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty
        else { return nil }
        return GenerateRequest(prompt: prompt, maxTokens: json["max_tokens"] as? Int)
    }
}

/// The pair request's body: the candidate's self-reported display name.
public struct PairRequest: Sendable, Equatable {
    public let deviceName: String

    public static func parse(_ body: Data?) -> PairRequest {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return PairRequest(deviceName: "A device") }
        return PairRequest(deviceName: name)
    }

    public init(deviceName: String) {
        self.deviceName = deviceName
    }
}

// MARK: - Remote-turn admission

/// Whether to serve a remote generation right now. Local activity and a warm
/// machine both refuse NEW remote turns (SPEC §8a.3: remote yields first) —
/// the client falls back to its own local ladder.
public enum RemoteTurnDecision: Sendable, Equatable {
    case serve
    case busyLocal(retryAfterSeconds: Int)
    case coolingDown(retryAfterSeconds: Int)
    /// The selected brain isn't ready to serve (still loading/downloading) —
    /// refusing here means a remote request can never TRIGGER a model load or
    /// multi-GB download as a side effect (2026-08-19 audit fold).
    case warmingUp(retryAfterSeconds: Int)
    /// Another remote generation is already streaming — the one MLX slot is
    /// single-flight, so concurrent remote turns are refused, never raced
    /// (2026-08-19 audit, finding 4).
    case busyRemote(retryAfterSeconds: Int)

    public static func decide(localBusy: Bool, thermalPressure: Bool, notReady: Bool = false) -> RemoteTurnDecision {
        if thermalPressure { return .coolingDown(retryAfterSeconds: 120) }
        if notReady { return .warmingUp(retryAfterSeconds: 30) }
        if localBusy { return .busyLocal(retryAfterSeconds: 15) }
        return .serve
    }
}

// MARK: - Wire frames

/// The listener's response frames. SSE responses are written as an HTTP head
/// followed by individually flushed event frames (spike A2 proved the client
/// sees them incrementally); everything else is a small buffered response.
public enum BrainServeFrames {
    public static func sseHead() -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
    }

    /// One token event. The payload is real JSON (encoder-escaped), so a
    /// token containing quotes/newlines can't break the frame.
    public static func tokenEvent(_ token: String) -> Data {
        struct Payload: Encodable { let token: String }
        let json = (try? JSONEncoder().encode(Payload(token: token)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"token":""}"#
        return Data("data: \(json)\n\n".utf8)
    }

    public static func doneEvent() -> Data {
        Data("event: done\ndata: {}\n\n".utf8)
    }

    public static func errorEvent(_ message: String) -> Data {
        struct Payload: Encodable { let message: String }
        let json = (try? JSONEncoder().encode(Payload(message: message)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"message":"error"}"#
        return Data("event: error\ndata: \(json)\n\n".utf8)
    }

    /// A small buffered response (health/pair/errors). Content-Length framed,
    /// Connection: close — the house one-request-per-connection shape.
    public static func buffered(status: Int, reason: String, json: String) -> Data {
        let body = Data(json.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    public static func busy(_ decision: RemoteTurnDecision) -> Data? {
        switch decision {
        case .serve:
            nil
        case let .busyLocal(seconds):
            retryAfter(seconds, reason: "busy")
        case let .coolingDown(seconds):
            retryAfter(seconds, reason: "cooling")
        case let .warmingUp(seconds):
            retryAfter(seconds, reason: "warming")
        case let .busyRemote(seconds):
            retryAfter(seconds, reason: "busy")
        }
    }

    private static func retryAfter(_ seconds: Int, reason: String) -> Data {
        let body = Data("{\"error\":\"\(reason)\",\"retry_after_s\":\(seconds)}".utf8)
        var head = "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\n"
        head += "Retry-After: \(seconds)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
