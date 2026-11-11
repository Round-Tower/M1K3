//
//  LocalAPIPolicies.swift
//  M1K3LocalAPI
//
//  The Local API's pure layer: M1K3's brains for other apps on this Mac,
//  through the wire shape OpenAI clients already speak. Routes, the loopback
//  gate, the chat request, errors, admission and stop sequences live here so
//  they can be tested in milliseconds; the listener (LocalAPIServer) is the
//  only part that touches the network.
//
//  What v1 is: text chat on the brains M1K3 ships and evaluates, raw (the
//  caller's system message is the whole system prompt; no persona, memory or
//  tools). Loopback only, off by default, behind its own access token.
//  What it is not: an assistant endpoint (MCP is), a runner for other
//  weights, tool calling, images, embeddings. Each of those is refused by
//  name so a client says what it wanted instead of failing quietly.
//
//  Its own listener and token, not the MCP server's: that server is built for
//  one path and JSON-RPC errors, and its token also unlocks memory and speech.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.8, Prior: none (new file)
//  Context: Kev, 2026-11-11: "1 more release before then with our current
//  work, and the server. Swiss army Mike!" Challenged before it was built.
//

import Foundation
import M1K3Inference

// MARK: - Routes

public enum LocalAPIRoute: Sendable, Equatable {
    case models
    case chatCompletions
    /// An OpenAI endpoint this server does not offer, named in the reply.
    case unsupported(String)
    /// A browser's CORS preflight. Refused: v1 has no browser clients.
    case preflight
    case notFound

    public static func classify(method: String, path: String) -> LocalAPIRoute {
        let method = method.uppercased()
        let path = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        if method == "OPTIONS" { return .preflight }
        switch (method, path) {
        case ("GET", "/v1/models"): return .models
        case ("POST", "/v1/chat/completions"): return .chatCompletions
        default: break
        }
        let known = ["/v1/completions", "/v1/embeddings", "/v1/responses", "/v1/audio/", "/v1/images/", "/v1/moderations"]
        if known.contains(where: { path == $0 || path.hasPrefix($0) }) { return .unsupported(path) }
        return .notFound
    }
}

// MARK: - Errors

/// A refusal in the shape OpenAI clients parse: `{"error": {message, type, code, param}}`.
/// Statuses are chosen for how those clients behave: they retry 408, 409, 429 and
/// 5xx by themselves, so only "try again shortly" uses one of those.
public struct LocalAPIError: Error, Sendable, Equatable {
    public let status: Int
    public let type: String
    public let code: String?
    public let message: String
    public let param: String?
    public let retryAfter: Int?

    public init(status: Int, type: String, code: String?, message: String, param: String? = nil, retryAfter: Int? = nil) {
        self.status = status
        self.type = type
        self.code = code
        self.message = message
        self.param = param
        self.retryAfter = retryAfter
    }

    public static func invalid(_ message: String, param: String? = nil) -> LocalAPIError {
        .init(status: 400, type: "invalid_request_error", code: nil, message: message, param: param)
    }

    public static let unauthorized = LocalAPIError(
        status: 401, type: "invalid_request_error", code: "invalid_api_key",
        message: "Send M1K3's Local API token as the API key (M1K3 ▸ Settings ▸ Local API)."
    )

    public static func forbidden(_ message: String) -> LocalAPIError {
        .init(status: 403, type: "invalid_request_error", code: nil, message: message)
    }

    public static func modelNotFound(_ id: String, available: [String]) -> LocalAPIError {
        let clipped = String(id.prefix(60))
        let offer = available.isEmpty ? "No brain is ready yet." : "Ready now: \(available.joined(separator: ", "))."
        return .init(
            status: 404, type: "invalid_request_error", code: "model_not_found",
            message: "The model '\(clipped)' is not loaded in M1K3. \(offer) M1K3 never swaps the brain you chose in "
                + "the app for a request; pick one that is ready.",
            param: "model"
        )
    }

    public static func busy(retryAfter: Int) -> LocalAPIError {
        .init(
            status: 429, type: "rate_limit_error", code: "busy",
            message: "M1K3 is answering someone else right now. The person at the Mac goes first; try again shortly.",
            retryAfter: retryAfter
        )
    }

    public static let contextTooLong = LocalAPIError(
        status: 400, type: "invalid_request_error", code: "context_length_exceeded",
        message: "The conversation is longer than this brain's context window.", param: "messages"
    )

    public static let refused = LocalAPIError(
        status: 400, type: "invalid_request_error", code: "content_filter",
        message: "This brain declined the request (its safety filter, or a language it does not speak)."
    )

    public static func unsupportedEndpoint(_ path: String) -> LocalAPIError {
        .init(
            status: 404, type: "invalid_request_error", code: "unsupported_endpoint",
            message: "M1K3's Local API offers /v1/models and /v1/chat/completions. \(String(path.prefix(60))) is not offered."
        )
    }

    public static func notFound(_ path: String) -> LocalAPIError {
        .init(status: 404, type: "invalid_request_error", code: nil, message: "Not found: \(String(path.prefix(60)))")
    }

    public static func server(_ message: String) -> LocalAPIError {
        .init(status: 500, type: "server_error", code: nil, message: message)
    }

    /// What a failed generation says to the client.
    public init(failure: any Error) {
        switch failure as? RawChatFailure {
        case .contextTooLong?: self = .contextTooLong
        case .refused?: self = .refused
        case .busy?: self = .busy(retryAfter: 5)
        case .failed?, nil: self = .server("The brain could not finish this answer.")
        }
    }

    public var body: Data {
        var error: [String: Any] = ["message": message, "type": type]
        error["code"] = code ?? NSNull()
        error["param"] = param ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: ["error": error], options: [.sortedKeys])) ?? Data()
    }
}

// MARK: - The gate

/// Who may speak to the listener: a client on this Mac that names this listener
/// and holds the token. A web page never: a browser sends an Origin, and v1 has
/// no browser clients, so any Origin is refused (that also ends DNS rebinding
/// together with the Host check).
public enum LocalAPIGate {
    public static func check(
        hosts: [String], origin: String?, authorization: String?, port: UInt16, token: String
    ) -> LocalAPIError? {
        guard hosts.count == 1, let host = hosts.first?.lowercased() else {
            return .invalid(hosts.isEmpty ? "Host header required" : "More than one Host header")
        }
        guard ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host) else {
            return .forbidden("This is M1K3's loopback listener; the Host header names something else.")
        }
        if origin != nil { return .forbidden("M1K3's Local API does not serve web pages.") }
        guard !token.isEmpty, let authorization else { return .unauthorized }
        let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer", constantTimeEqual(parts[1], token) else {
            return .unauthorized
        }
        return nil
    }

    /// Compares every byte whatever the first mismatch, so timing says nothing about the token.
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        for index in 0 ..< max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }
}

// MARK: - The chat request

public struct ChatCompletionCall: Sendable, Equatable {
    public let model: String
    public let request: RawChatRequest
    public let stream: Bool
    public let includeUsage: Bool
    public let stop: [String]

    public static func parse(_ body: Data?) -> Result<ChatCompletionCall, LocalAPIError> {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failure(.invalid("The request body must be a JSON object."))
        }
        guard let model = object["model"] as? String, !model.isEmpty else {
            return .failure(.invalid("model is required", param: "model"))
        }
        guard let rawMessages = object["messages"] as? [[String: Any]] else {
            return .failure(.invalid("messages is required", param: "messages"))
        }
        if let tools = object["tools"] as? [Any], !tools.isEmpty {
            return .failure(.invalid("Tool calling is not offered by M1K3's Local API.", param: "tools"))
        }
        if object["functions"] != nil {
            return .failure(.invalid("Function calling is not offered by M1K3's Local API.", param: "functions"))
        }
        if let count = object["n"] as? Int, count != 1 {
            return .failure(.invalid("Only n = 1 is supported.", param: "n"))
        }
        if let format = object["response_format"] as? [String: Any], (format["type"] as? String ?? "text") != "text" {
            return .failure(.invalid("Only text responses are supported.", param: "response_format"))
        }
        var messages: [RawChatMessage] = []
        for raw in rawMessages {
            let role: RawChatMessage.Role
            switch raw["role"] as? String {
            case "system", "developer": role = .system
            case "user": role = .user
            case "assistant": role = .assistant
            default:
                return .failure(.invalid("Only system, user and assistant messages are supported.", param: "messages"))
            }
            guard let text = textContent(raw["content"]) else {
                return .failure(.invalid("Only text content is supported.", param: "messages"))
            }
            messages.append(RawChatMessage(role, text))
        }
        let maxTokens = (object["max_completion_tokens"] as? Int) ?? (object["max_tokens"] as? Int)
        let temperature = (object["temperature"] as? NSNumber)?.doubleValue
        let request: RawChatRequest
        do {
            request = try RawChatRequest(messages: messages, maxTokens: maxTokens, temperature: temperature)
        } catch let invalid as RawChatRequest.Invalid {
            return .failure(.invalid(invalid.message, param: invalid == .badMaxTokens ? "max_tokens" : "messages"))
        } catch {
            return .failure(.invalid("The messages could not be read.", param: "messages"))
        }
        var stop: [String] = []
        if let one = object["stop"] as? String { stop = [one] }
        if let many = object["stop"] as? [String] { stop = many }
        let options = object["stream_options"] as? [String: Any]
        return .success(ChatCompletionCall(
            model: model, request: request, stream: object["stream"] as? Bool ?? false,
            includeUsage: options?["include_usage"] as? Bool ?? false,
            stop: stop.filter { !$0.isEmpty }.prefix(4).map { $0 }
        ))
    }

    /// A message's text: a string, or an array of text parts joined. Nil for anything else (an image part).
    private static func textContent(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]], !parts.isEmpty else { return nil }
        var text = ""
        for part in parts {
            guard part["type"] as? String == "text", let piece = part["text"] as? String else { return nil }
            text += piece
        }
        return text
    }
}

// MARK: - Models and admission

public enum LocalAPIModel {
    /// The API id of one of M1K3's brains, from its tier's raw name ("lil" → "m1k3-lil").
    public static func id(forTier tier: String) -> String {
        "m1k3-" + tier.lowercased()
    }
}

/// Whether one chat call may start. The order matters: a model that is not
/// there is named before a queue is, so a client fixes its config instead of
/// retrying a model that will never load.
public enum LocalAPIAdmission {
    public static func decide(requested: String, available: [String], userBusy: Bool, apiBusy: Bool) -> LocalAPIError? {
        guard available.contains(requested) else { return .modelNotFound(requested, available: available) }
        if userBusy { return .busy(retryAfter: 10) }
        if apiBusy { return .busy(retryAfter: 3) }
        return nil
    }
}

// MARK: - Stop sequences

/// Ends an answer at the first stop sequence, even when it arrives split across
/// deltas: the longest tail that could still begin a sequence is held back.
public struct StopSequenceFilter: Sendable {
    private let stops: [String]
    private var held = ""

    public init(stops: [String]) {
        self.stops = stops.filter { !$0.isEmpty }
    }

    public mutating func push(_ delta: String) -> (emit: String, stopped: Bool) {
        guard !stops.isEmpty else { return (delta, false) }
        held += delta
        if let cut = stops.compactMap({ held.range(of: $0)?.lowerBound }).min() {
            let emit = String(held[..<cut])
            held = ""
            return (emit, true)
        }
        var keep = 0
        for stop in stops {
            for length in stride(from: min(stop.count - 1, held.count), to: 0, by: -1)
                where held.hasSuffix(String(stop.prefix(length)))
            {
                keep = max(keep, length)
                break
            }
        }
        let emit = String(held.dropLast(keep))
        held = String(held.suffix(keep))
        return (emit, false)
    }

    /// What was held back, once the stream has ended without a stop sequence.
    public mutating func flush() -> String {
        defer { held = "" }
        return held
    }
}
