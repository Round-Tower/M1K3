//
//  LocalAPIWire.swift
//  M1K3LocalAPI
//
//  The bytes the Local API reads and writes: a small HTTP/1.1 request reader
//  (one request per connection, Content-Length bodies only), buffered JSON
//  responses, and the server-sent-event frames of a streamed chat completion.
//  Pure, so the frames an OpenAI client depends on are pinned by tests.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.8, Prior: none (new file)
//

import Foundation
import M1K3Inference

public struct LocalAPIRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    /// Header values by lowercased name, in arrival order (a duplicated Host must be seen as two).
    public let headers: [String: [String]]
    public let body: Data

    public func first(_ name: String) -> String? {
        headers[name.lowercased()]?.first
    }
}

public enum LocalAPIHTTP {
    /// The largest body the listener reads. A chat request is text; this is generous for it.
    public static let maxBodyBytes = 4 * 1024 * 1024

    /// The largest request head. Read before anyone has shown a key, so it is small.
    public static let maxHeadBytes = 16 * 1024

    private static let separator = Data("\r\n\r\n".utf8)

    /// Whether the head is over the cap: no end of head within it, or an end beyond it.
    public static func headIsTooLarge(_ data: Data) -> Bool {
        guard let range = data.range(of: separator) else { return data.count > maxHeadBytes }
        return range.lowerBound - data.startIndex > maxHeadBytes
    }

    /// The Content-Length a head declares, once the head has arrived (nil before; 0 when absent).
    public static func declaredLength(_ data: Data) -> Int? {
        guard let head = head(of: data) else { return nil }
        for line in head.lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return 0
    }

    /// The request, once its head and its whole body have arrived. Nil while incomplete or when it is not HTTP.
    public static func parse(_ data: Data) -> LocalAPIRequest? {
        guard let head = head(of: data), let requestLine = head.lines.first else { return nil }
        let words = requestLine.split(separator: " ")
        guard words.count == 3, words[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: [String]] = [:]
        for line in head.lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[line[..<colon].lowercased(), default: []].append(value)
        }
        let length = headers["content-length"]?.first.flatMap(Int.init) ?? 0
        guard length >= 0, data.count - head.bodyStart >= length else { return nil }
        let body = data.subdata(in: (data.startIndex + head.bodyStart) ..< (data.startIndex + head.bodyStart + length))
        return LocalAPIRequest(method: String(words[0]), path: String(words[1]), headers: headers, body: body)
    }

    private static func head(of data: Data) -> (lines: [String], bodyStart: Int)? {
        guard let range = data.range(of: separator),
              let text = String(data: data[data.startIndex ..< range.lowerBound], encoding: .utf8)
        else { return nil }
        return (text.components(separatedBy: "\r\n"), range.upperBound - data.startIndex)
    }
}

public enum LocalAPIWire {
    // MARK: Buffered

    public static func response(status: Int, body: Data, retryAfter: Int? = nil) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      413: "Payload Too Large", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
                      500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        if let retryAfter { head += "Retry-After: \(retryAfter)\r\n" }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    public static func response(for error: LocalAPIError) -> Data {
        response(status: error.status, body: error.body, retryAfter: error.retryAfter)
    }

    public static func modelsBody(ids: [String], created: Int) -> Data {
        let data = ids.map { ["id": $0, "object": "model", "created": created, "owned_by": "m1k3"] as [String: Any] }
        return encode(["object": "list", "data": data])
    }

    public static func completionBody(id: String, model: String, created: Int, text: String, finish: RawChatFinish) -> Data {
        encode([
            "id": id, "object": "chat.completion", "created": created, "model": model,
            "choices": [[
                "index": 0, "finish_reason": finish.reason.rawValue,
                "message": ["role": "assistant", "content": text],
            ] as [String: Any]],
            "usage": usage(finish),
        ])
    }

    // MARK: Streamed

    public static let sseHead = Data(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8
    )

    public static let done = Data("data: [DONE]\n\n".utf8)

    /// One chunk: the opening role, a content delta, or the closing finish reason.
    public static func chunk(
        id: String, model: String, created: Int, role: Bool = false, content: String? = nil,
        finish: RawChatFinish.Reason? = nil
    ) -> Data {
        var delta: [String: Any] = [:]
        if role { delta["role"] = "assistant" }
        if let content { delta["content"] = content }
        return event([
            "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
            "choices": [[
                "index": 0, "delta": delta, "finish_reason": finish.map { $0.rawValue as Any } ?? NSNull(),
            ] as [String: Any]],
        ])
    }

    /// The trailing usage chunk a client asks for with `stream_options.include_usage`.
    public static func usageChunk(id: String, model: String, created: Int, finish: RawChatFinish) -> Data {
        event([
            "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
            "choices": [Any](), "usage": usage(finish),
        ])
    }

    /// A failure after the stream began: the status line has gone, so the error rides as an event.
    public static func errorEvent(_ error: LocalAPIError) -> Data {
        Data("data: ".utf8) + error.body + Data("\n\n".utf8)
    }

    // MARK: Helpers

    /// Zeros where the runtime reports no counts (Apple's model), so a client that reads usage does not fail.
    private static func usage(_ finish: RawChatFinish) -> [String: Any] {
        let prompt = finish.promptTokens ?? 0, completion = finish.completionTokens ?? 0
        return ["prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion]
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func event(_ object: [String: Any]) -> Data {
        Data("data: ".utf8) + encode(object) + Data("\n\n".utf8)
    }
}
