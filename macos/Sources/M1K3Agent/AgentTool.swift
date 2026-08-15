//
//  AgentTool.swift
//  M1K3Agent
//
//  A capability the LocalAgent can invoke during its ReAct loop. M1K3's MVP
//  tools wrap the knowledge layer (search_knowledge, query_graph, get_document,
//  list_documents); they're injected, so the agent stays decoupled from the
//  store and testable against fakes.
//
//  Ported from the prior call-pipeline's AgentTool / ToolParameter / ToolResult.
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.9,
//  Prior: internal call-pipeline project, AgentTool + ToolResult (Kev)

import Foundation

/// A named input a tool accepts. The first parameter receives the agent's
/// positional argument (`ToolName(value)`); richer multi-arg parsing is a
/// future enhancement.
public struct ToolParameter: Sendable, Equatable {
    public let name: String
    public let description: String
    /// Whether the wire schema lists this parameter in `required`. Defaults to
    /// true (the historical contract); optional parameters (e.g. get_document's
    /// resume `offset`) must say so, or prompt-fragile native tool-callers see
    /// a schema that contradicts the prose and loop-thrash supplying it.
    public let isRequired: Bool

    public init(name: String, description: String, isRequired: Bool = true) {
        self.name = name
        self.description = description
        self.isRequired = isRequired
    }
}

/// The text a tool returns to the agent as an observation. By convention an
/// output beginning with "Error:" is surfaced as a failed-but-recoverable step.
public struct ToolResult: Sendable, Equatable {
    public let output: String

    public init(output: String) {
        self.output = output
    }
}

public protocol AgentTool: Sendable {
    /// Identifier the agent uses in `ACTION: name(arg)`.
    var name: String { get }
    /// One-line description shown to the model so it knows when to call this.
    var description: String { get }
    /// Declared parameters. The first receives the positional argument.
    var parameters: [ToolParameter] { get }
    /// Execute against a name→value input map and return an observation.
    ///
    /// Error contract: failures the MODEL should see (network down, no
    /// results, bad page) are returned as "Error: …" observations, never
    /// thrown — the loop feeds them back so the model can adapt. `throws`
    /// stays in the signature for genuinely unrecoverable tool states; the
    /// built-in web/OS tools deliberately never use it.
    func execute(input: [String: String]) async throws -> ToolResult

    /// Whether this tool contends for the process's single Metal/MLX compute
    /// lane (query embedding, delegated generation). When one model turn
    /// carries several tool calls, exclusive tools execute serially relative
    /// to EACH OTHER while everything else fans out concurrently — two
    /// concurrent MLX workloads stall each other (the one-decode-loop
    /// doctrine), but network/disk tools overlap freely. Default false.
    var requiresExclusiveCompute: Bool { get }
}

public extension AgentTool {
    /// Default: a plain network/disk/pure tool — safe to run concurrently.
    var requiresExclusiveCompute: Bool {
        false
    }
}
