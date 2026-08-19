//
//  MCPToolRegistry.swift
//  M1K3MCPKit
//
//  The injectable tool registry every M1K3 MCP transport serves from: the
//  stdio executable registers knowledge tools, the in-app HTTP server adds
//  voice tools on top. Handlers return plain text; errors become isError
//  results, never protocol failures.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.9 (pure dispatch,
//  test-pinned). Prior: Unknown.
//  Review: claude-fable-5, 2026-08-19 — MCPCallLogEntry gained `clientName` +
//  `stamped(clientName:)` (the Agent Log identity column; registry itself
//  stays identity-blind — the transport-side sink stamps).
//

import Foundation
import MCP
import os

/// One recorded MCP tool call — the request (tool + arguments) and its response.
/// This is the readable-chat unit the agent-interaction log stores. It carries
/// the arguments and response text verbatim, so it only exists when a sink is
/// wired (opt-in) — the registry never builds one otherwise.
public struct MCPCallLogEntry: Sendable {
    public let tool: String
    public let arguments: [String: Value]?
    public let responseText: String
    public let isError: Bool
    public let durationMS: Int
    /// The calling client's self-reported name (from the MCP initialize's
    /// clientInfo). The registry never fills this — it doesn't know the
    /// session; the app's sink wrapper stamps it before the store. Untrusted
    /// display data.
    public let clientName: String?

    public init(
        tool: String, arguments: [String: Value]?, responseText: String,
        isError: Bool, durationMS: Int, clientName: String? = nil
    ) {
        self.tool = tool
        self.arguments = arguments
        self.responseText = responseText
        self.isError = isError
        self.durationMS = durationMS
        self.clientName = clientName
    }

    /// The same entry with the client identity stamped on.
    public func stamped(clientName: String?) -> MCPCallLogEntry {
        MCPCallLogEntry(
            tool: tool, arguments: arguments, responseText: responseText,
            isError: isError, durationMS: durationMS, clientName: clientName
        )
    }
}

/// Where recorded calls go. The concrete implementation (a GRDB store) lives in
/// the app shell and self-gates on the user's opt-in toggle; the registry just
/// hands it every call it dispatches. Kept dependency-free here so the core
/// stays testable without persistence.
public protocol MCPCallLogSink: Sendable {
    func record(_ entry: MCPCallLogEntry)
}

/// One tool: its MCP declaration plus the handler that runs it.
public struct MCPToolDefinition: Sendable {
    public let tool: Tool
    public let handler: @Sendable ([String: Value]?) async throws -> String

    public init(tool: Tool, handler: @escaping @Sendable ([String: Value]?) async throws -> String) {
        self.tool = tool
        self.handler = handler
    }
}

/// Name-keyed dispatch over a fixed set of tool definitions.
public struct MCPToolRegistry: Sendable {
    private static let log = Logger(subsystem: "app.m1k3", category: "mcp")
    private let definitions: [MCPToolDefinition]
    private let logSink: (any MCPCallLogSink)?

    public init(_ definitions: [MCPToolDefinition], logSink: (any MCPCallLogSink)? = nil) {
        self.definitions = definitions
        self.logSink = logSink
    }

    /// Declarations in registration order (ListTools).
    public var tools: [Tool] {
        definitions.map(\.tool)
    }

    /// Run a tool by name. Unknown names and handler throws both surface as
    /// `isError` results — observations for the client, never crashes.
    ///
    /// When a log sink is wired (opt-in), every dispatch is recorded verbatim
    /// (request + response) for the agent-interaction log. With no sink this is
    /// byte-for-byte the original dispatch — zero capture, zero overhead.
    public func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let logSink else { return await dispatch(name: name, arguments: arguments) }

        let start = Date()
        let result = await dispatch(name: name, arguments: arguments)
        logSink.record(MCPCallLogEntry(
            tool: name,
            arguments: arguments,
            responseText: Self.firstText(of: result) ?? "",
            isError: result.isError == true,
            durationMS: Int(Date().timeIntervalSince(start) * 1000)
        ))
        return result
    }

    private func dispatch(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let definition = definitions.first(where: { $0.tool.name == name }) else {
            return CallTool.Result(
                content: [.text(text: "Unknown tool: \(name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        do {
            let text = try await definition.handler(arguments)
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
        } catch {
            // The client gets isError, but Kev debugging from the app's own logs
            // saw nothing for a thrown tool — record the tool NAME (never args: PII).
            Self.log.error("tool \"\(name, privacy: .public)\" threw: \(error.localizedDescription, privacy: .public)")
            return CallTool.Result(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    private static func firstText(of result: CallTool.Result) -> String? {
        if case let .text(text, _, _) = result.content.first { return text }
        return nil
    }
}

// MARK: - Argument helpers

public func stringArg(_ args: [String: Value]?, _ key: String) -> String? {
    if case let .string(value)? = args?[key] { return value }
    return nil
}

public func intArg(_ args: [String: Value]?, _ key: String) -> Int? {
    if case let .int(value)? = args?[key] { return value }
    return nil
}

public func doubleArg(_ args: [String: Value]?, _ key: String) -> Double? {
    switch args?[key] {
    case let .double(value): return value
    case let .int(value): return Double(value) // JSON clients send 30 for 30.0
    default: return nil
    }
}

public func boolArg(_ args: [String: Value]?, _ key: String) -> Bool? {
    if case let .bool(value)? = args?[key] { return value }
    return nil
}
