//
//  JSONRPC.swift
//  M1K3CLICore
//
//  The two frames `m1k3` puts on the wire, and the reading of what comes back.
//  The app's loopback server is the MCP SDK's StatelessHTTPServerTransport, so
//  the encoder mirrors the SDK's own (`.sortedKeys` + `.withoutEscapingSlashes`)
//  and ids are integers, never strings.
//
//  ★ THE ONE RULE: never send `initialize` speculatively. The app's
//  LocalMCPHTTPServer sniffs initialize POSTs and REBUILDS the (Server,
//  transport) pair — v1 is one MCP client at a time — and each initialize
//  re-stamps the visitor name the notch HUD captions. A CLI that opened every
//  invocation with a handshake would evict the coding agent that is actually
//  connected, mid-conversation, and rename the face on screen to "m1k3-cli".
//  So: send the tools/call first, and only handshake if the server answers
//  `.notInitialized` (nothing has claimed the session yet).
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.85 (frames are
//  byte-pinned against the SDK the app links; the `.notInitialized` sentinel
//  matches the SDK's own wording — "Invalid Request: Server is not
//  initialized" — which is the one string that could drift on an SDK bump).
//  Prior: Unknown.
//

import Foundation

/// A JSON value that survives a round trip without Foundation's NSNumber
/// ambiguity — the reason `m1k3 call` can forward a user's raw JSON verbatim
/// and still send `true` as a bool and `1` as an integer.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Decode a JSON object literal (what `m1k3 call` is handed) into arguments.
    public static func arguments(fromJSON json: String) throws -> [String: JSONValue] {
        guard let data = json.data(using: .utf8) else { return [:] }
        guard case let .object(fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw JSONRPC.WireError("arguments must be a JSON object")
        }
        return fields
    }
}

public enum JSONRPC {
    /// The MCP revision `m1k3` asks for. In the SDK's supported set, so the
    /// server negotiates it back unchanged.
    public static let protocolVersion = "2025-06-18"

    /// What the notch HUD captions when the CLI is the one talking.
    public static let defaultClientName = "m1k3-cli"

    public struct WireError: Error, Equatable, Sendable {
        public let message: String
        public init(_ message: String) {
            self.message = message
        }
    }

    // MARK: - Requests

    public static func toolsCall(
        name: String,
        arguments: [String: JSONValue],
        id: Int = 1
    ) throws -> Data {
        try encode(Request(id: id, method: "tools/call", params: CallParams(name: name, arguments: arguments)))
    }

    /// The readiness probe used while waiting for a cold app: READ-ONLY, so
    /// polling with it can never run a tool twice. (Polling with the real body
    /// would have `remember` store twice and `speak` speak twice.)
    public static func toolsList(id: Int = 1) throws -> Data {
        try encode(Request(id: id, method: "tools/list", params: Empty()))
    }

    /// The handshake — only ever sent in recovery. See the file header.
    public static func initialize(
        clientName: String = defaultClientName,
        clientVersion: String,
        id: Int = 1
    ) throws -> Data {
        try encode(Request(
            id: id,
            method: "initialize",
            params: InitializeParams(
                protocolVersion: protocolVersion,
                capabilities: Empty(),
                clientInfo: ClientInfo(name: clientName, version: clientVersion)
            )
        ))
    }

    // MARK: - Replies

    public enum Reply: Equatable, Sendable {
        case text(String)
        case error(code: Int, message: String)
        /// The server has no session yet — send `initialize` and retry once.
        case notInitialized

        /// JSON-RPC's own "Parse error" code, reused for an answer we could
        /// not read at all.
        public static let parseErrorCode = -32700
        /// A tool that ran and failed reports `isError` inside a perfectly
        /// valid result; JSON-RPC has no code for that, so we mint one in the
        /// implementation-defined server-error range.
        public static let toolFailureCode = -32000

        /// Read an HTTP answer.
        ///
        /// ★ The ENVELOPE is authoritative whatever the status code. The MCP
        /// SDK answers protocol errors with a 4xx AND a proper JSON-RPC error
        /// object, so a status-first reading turns the one RECOVERABLE refusal
        /// — "Server is not initialized" — into a dead-end "answered HTTP 400"
        /// and the handshake never fires on a freshly-launched app. The status
        /// only speaks when there is no envelope to read (a proxy's HTML error
        /// page, say), which is exactly when it is the whole story.
        public static func parse(status: Int, body: Data) -> Reply {
            let hasEnvelope = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
                .map { $0["result"] != nil || $0["error"] != nil } ?? false
            guard hasEnvelope || (200 ..< 300).contains(status) else {
                let preview = String(data: body.prefix(200), encoding: .utf8) ?? "\(body.count) bytes"
                return .error(code: status, message: "M1K3's MCP server answered HTTP \(status). \(preview)")
            }
            return parse(body)
        }

        public static func parse(_ data: Data) -> Reply {
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                let preview = String(data: data.prefix(200), encoding: .utf8) ?? "\(data.count) bytes"
                return .error(code: parseErrorCode, message: "couldn't read M1K3's answer: \(preview)")
            }
            if let error = root["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "unknown error"
                let code = error["code"] as? Int ?? parseErrorCode
                // The SDK refuses a call before initialize with
                // MCPError.invalidRequest("Server is not initialized") — the
                // one refusal that is a handshake away from success.
                if message.lowercased().contains("not initialized") { return .notInitialized }
                return .error(code: code, message: message)
            }
            guard let result = root["result"] as? [String: Any] else {
                return .error(code: parseErrorCode, message: "M1K3's answer had neither a result nor an error")
            }
            let joined = joinText(result["content"])
            if result["isError"] as? Bool == true {
                return .error(code: toolFailureCode, message: joined)
            }
            return .text(joined)
        }

        /// MCP content is a list of parts; M1K3's tools only ever emit text,
        /// but a future image part must not turn an answer into a crash.
        private static func joinText(_ content: Any?) -> String {
            guard let parts = content as? [[String: Any]] else { return "" }
            return parts
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        }
    }

    // MARK: - Encoding

    private struct Request<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: Params
    }

    private struct CallParams: Encodable {
        let name: String
        let arguments: [String: JSONValue]
    }

    private struct InitializeParams: Encodable {
        let protocolVersion: String
        let capabilities: Empty
        let clientInfo: ClientInfo
    }

    private struct ClientInfo: Encodable {
        let name: String
        let version: String
    }

    /// Encodes as `{}` — an MCP client with no capabilities to declare.
    private struct Empty: Encodable {}

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        // The SDK's own settings: deterministic key order (so these frames are
        // byte-pinnable) and readable URLs in the body.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
