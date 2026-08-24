//
//  BrainLinkWire.swift
//  M1K3BrainLink
//
//  The client's half of the Brain at Home wire: HTTP/1.1 request builders,
//  the response-head parser, and an incremental SSE event parser. All pure —
//  the NWConnection transport feeds bytes in whatever chunks the network
//  hands it, and these types are pinned against the server's OWN frame
//  encoders (BrainLinkWireTests) so the two ends can't drift.
//
//  Deliberately minimal HTTP: the server speaks exactly one dialect
//  (HTTP/1.1, Connection: close, Content-Length or SSE) — this is a codec
//  for THAT dialect, not a general client.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.9 (pure, TDD'd
//  against real BrainServeFrames bytes). Prior: BrainServePolicies.swift
//  (the server's frame encoders, Kev + claude-fable-5 2026-08-19).
//

import Foundation

// MARK: - Requests

public enum BrainLinkFrames {
    public static func get(_ path: String, host: String) -> Data {
        Data(
            "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                .utf8
        )
    }

    public static func post(_ path: String, host: String, body: Data) -> Data {
        var head = "POST \(path) HTTP/1.1\r\nHost: \(host)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        head += "Accept: */*\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// The /v1/pair body — the device's self-reported display name.
    public static func pairBody(deviceName: String) -> Data {
        struct Body: Encodable { let name: String }
        return (try? JSONEncoder().encode(Body(name: deviceName))) ?? Data("{}".utf8)
    }

    /// The /v1/generate body. `max_tokens` omitted when nil (the server
    /// treats absence as "the provider's own cap").
    public static func generateBody(prompt: String, maxTokens: Int?) -> Data {
        struct Body: Encodable {
            let prompt: String
            let max_tokens: Int?
        }
        let encoder = JSONEncoder()
        return (try? encoder.encode(Body(prompt: prompt, max_tokens: maxTokens)))
            ?? Data(#"{"prompt":""}"#.utf8)
    }
}

// MARK: - Response head

public struct HTTPResponseHead: Sendable, Equatable {
    public let status: Int
    public let reason: String
    /// Header names lowercased; last value wins (the server never repeats).
    public let headers: [String: String]

    public var contentLength: Int? {
        headers["content-length"].flatMap(Int.init)
    }

    public var isEventStream: Bool {
        headers["content-type"]?.lowercased().contains("text/event-stream") == true
    }

    public var retryAfterSeconds: Int? {
        headers["retry-after"].flatMap(Int.init)
    }
}

public enum HTTPResponseParser {
    /// Parse a response head from accumulated bytes. nil until the blank line
    /// has arrived, or for a status line that isn't HTTP. `bodyStart` indexes
    /// into the SAME data the caller passed (absolute, not relative).
    public static func parseHead(_ data: Data) -> (head: HTTPResponseHead, bodyStart: Int)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = data.range(of: separator) else { return nil }
        guard let headText = String(data: data.subdata(in: data.startIndex ..< separatorRange.lowerBound), encoding: .utf8)
        else { return nil }
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst()
        // "HTTP/1.1 200 OK" — version SP status SP reason(with spaces)
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/"),
              let status = Int(statusParts[1])
        else { return nil }
        let reason = statusParts.count > 2 ? String(statusParts[2]) : ""
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (
            HTTPResponseHead(status: status, reason: reason, headers: headers),
            separatorRange.upperBound
        )
    }
}

// MARK: - SSE

/// Incremental server-sent-events parser for the /v1/generate stream. Feed
/// it chunks as they arrive; it emits complete events and buffers partials.
/// Unknown event kinds and unparseable payloads are skipped, not fatal —
/// forward compatibility on a stream we also author.
public struct SSEParser: Sendable {
    public enum Event: Sendable, Equatable {
        case token(String)
        case done
        case error(String)
    }

    private var buffer = Data()

    public init() {}

    public mutating func feed(_ data: Data) -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        let frameEnd = Data("\n\n".utf8)
        while let range = buffer.range(of: frameEnd) {
            let frame = buffer.subdata(in: buffer.startIndex ..< range.lowerBound)
            buffer.removeSubrange(buffer.startIndex ..< range.upperBound)
            if let event = Self.parseFrame(frame) {
                events.append(event)
            }
        }
        return events
    }

    private static func parseFrame(_ frame: Data) -> Event? {
        guard let text = String(data: frame, encoding: .utf8) else { return nil }
        var eventName = "message"
        var dataLine: String?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLine = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        switch eventName {
        case "message":
            struct TokenPayload: Decodable { let token: String }
            guard let dataLine,
                  let payload = try? JSONDecoder().decode(TokenPayload.self, from: Data(dataLine.utf8))
            else { return nil }
            return .token(payload.token)
        case "done":
            return .done
        case "error":
            struct ErrorPayload: Decodable { let message: String }
            let message = dataLine
                .flatMap { try? JSONDecoder().decode(ErrorPayload.self, from: Data($0.utf8)) }?
                .message ?? "stream error"
            return .error(message)
        default:
            return nil
        }
    }
}
