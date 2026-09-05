//
//  ToolCallingProvider.swift
//  M1K3Inference
//
//  Phase 12a — the capability seam for NATIVE tool calling. Most models speak
//  their own tool-call dialect (Gemma `call:name{…}`, Qwen/Llama `<tool_call>`
//  JSON, Apple Foundation Models' native `Tool` protocol). A `ToolCallingProvider`
//  is an `InferenceProvider` that parses its model's dialect into structured
//  `ToolTurn`s, so the agent never text-scrapes — and stays model-AGNOSTIC: the
//  per-model format mapping lives inside each adapter, never in the agent.
//
//  Runtimes with no tool support simply don't conform, so the prompt-ReAct loop
//  remains the universal floor (LocalAgent uses the native path only when the
//  active provider conforms AND reports `supportsToolCalls`).
//
//  Why a typed transcript, not a prompt string (challenger pass, 2026-06-10):
//  native models render tool definitions and tool RESULTS into role-tagged turns
//  they were trained on. Feeding results back as concatenated prose is
//  off-distribution and breaks small models. So the agent owns the conversation
//  as `[ToolMessage]` data; the provider renders it into its model's chat
//  template. This is also exactly the shape mlx-swift-lm's
//  `UserInput(chat: [Chat.Message])` wants — so the MLX adapter (12c) maps the
//  array straight through with no seam churn.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-10, Confidence 0.85, Prior: Unknown
//  Context: foundational multi-model tool-calling seam; pressure-tested by the
//  challenger (typed transcript + typed args + runtime capability flag adopted;
//  full TurnStrategy extraction deferred — runNative reuses the shared dispatch
//  helpers rather than rewriting the proven ReAct path).
//  Review: Kev + claude-fable-5, 2026-06-11, Confidence 0.9 — PR #16 review
//  follow-ups: JSONValue Codable is now MANUAL RFC-8259 (the synthesized
//  encoding was wire-garbage for the .json dialect, test-pinned);
//  supportsToolCalls default flipped to false (native loop is opt-in).

import Foundation
import Synchronization

/// A JSON value as it arrives from a model's native tool-call output. Tool-call
/// arguments are genuinely typed (numbers, bools, nested objects), so the WIRE
/// preserves them; callers flatten to `String` at the execution edge if their
/// tool only takes text. Typing the wire now avoids a breaking change to a
/// public protocol when a multi-arg typed tool lands.
public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Codable is MANUAL: the SE-0295 synthesized conformance wraps each case
    /// in a discriminant container (`{"string":{"_0":"seals"}}`), which is
    /// not JSON a model can read — the `.json` tool-call dialect echoes these
    /// values back into the chat transcript, so they must encode as the plain
    /// JSON they represent (PR #16 review finding).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(values): try container.encode(values)
        case let .object(pairs): try container.encode(pairs)
        case .null: try container.encodeNil()
        }
    }

    /// A flat string rendering for tools that take plain text. Scalars render
    /// naturally; containers fall back to their JSON-ish description.
    public var stringValue: String {
        switch self {
        case let .string(value): value
        case let .int(value): String(value)
        case let .double(value): String(value)
        case let .bool(value): String(value)
        case .null: ""
        case let .array(values): values.map(\.stringValue).joined(separator: ", ")
        case let .object(pairs):
            pairs.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.stringValue)" }
                .joined(separator: ", ")
        }
    }
}

/// One declared parameter of a tool, dialect-free. Each adapter projects this
/// into its model's schema format (JSON Schema for MLX/AFM).
public struct ToolParameterDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    /// JSON-schema type ("string", "integer", "boolean", …). Defaults to string
    /// since every current M1K3 tool takes one text argument.
    public let type: String
    public let isRequired: Bool

    public init(name: String, description: String, type: String = "string", isRequired: Bool = true) {
        self.name = name
        self.description = description
        self.type = type
        self.isRequired = isRequired
    }
}

/// A tool the model may call, described dialect-free. `AgentTool` projects to
/// this (see `AgentTool.toolDefinition`); the provider renders it natively.
public struct ToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: [ToolParameterDefinition]

    public init(name: String, description: String, parameters: [ToolParameterDefinition]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A tool call the model asked for — already parsed out of the model's native
/// dialect by the provider, so the agent receives structure, not text.
public struct ParsedToolCall: Sendable, Equatable {
    public let name: String
    public let arguments: [String: JSONValue]

    public init(name: String, arguments: [String: JSONValue]) {
        self.name = name
        self.arguments = arguments
    }

    /// Arguments flattened to text for the current single-positional `AgentTool`
    /// contract. Keys are preserved; values are string-rendered.
    public var stringArguments: [String: String] {
        arguments.mapValues(\.stringValue)
    }
}

/// One turn from a tool-capable model: either a final text answer, or one or
/// more tool calls to execute and feed back as results.
public enum ToolTurn: Sendable, Equatable {
    case text(String)
    case toolCalls([ParsedToolCall])
}

/// A role-tagged turn in the agent↔model conversation. The agent owns the
/// transcript as `[ToolMessage]`; the provider renders it into its model's chat
/// template (system/user/assistant/tool roles). This is the durable contract
/// that survives whether the adapter is stateless-renders-array or stateful.
public enum ToolMessage: Sendable, Equatable {
    /// The standing persona/instructions, rendered into the chat template's
    /// system turn. Sent once, at the start of a turn's transcript.
    case system(String)
    /// The opening instruction + goal (and any grounding context), plus any
    /// images the user attached to the turn. Only a vision-capable provider
    /// consumes the images (BrainTier.supportsImageInput); every other
    /// renderer drops them loudly at its mapping site.
    case user(String, images: [ImageAttachment])
    /// What the model produced last turn — free text and/or the tool calls it
    /// requested. Threaded back so the model sees its own prior calls correctly.
    case assistant(text: String?, toolCalls: [ParsedToolCall])
    /// The observation from executing one tool call, role-tagged as a result.
    case toolResult(name: String, output: String)

    /// Source-compatible bare-text user turn — identical to
    /// `.user(text, images: [])`, so no pre-vision call site changes.
    public static func user(_ text: String) -> ToolMessage {
        .user(text, images: [])
    }
}

/// Per-turn options for a tool session. Extend here rather than growing the
/// protocol signature again.
public struct ToolTurnOptions: Sendable, Equatable {
    /// Whether the model may spend a reasoning phase this turn. Providers
    /// whose template has no thinking switch ignore it.
    public let thinkingEnabled: Bool

    public init(thinkingEnabled: Bool = true) {
        self.thinkingEnabled = thinkingEnabled
    }

    public static let `default` = ToolTurnOptions()
}

/// A stateful conversation with a tool-capable model for ONE agent turn. The
/// caller sends only the NEW messages each iteration — the session retains
/// everything prior (for MLX that's a live KV cache, so iteration N prefills
/// only the new tool results instead of re-prefilling the whole transcript).
///
/// Contract: for a `.text` outcome the session must have delivered the FULL
/// turn text through `onToken` (chunked or in one piece) — the agent's live
/// streaming gate derives what is still unemitted from that stream.
public protocol ToolTurnSession: AnyObject, Sendable {
    /// Append `messages` to the conversation and generate the model's next
    /// turn, streaming raw text through `onToken` as it is produced.
    func send(
        _ messages: [ToolMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> ToolTurn

    /// The turn is over: release per-turn resources (KV cache, pooled buffers).
    func finish() async
}

public extension ToolTurnSession {
    func finish() async {}
}

/// Where the per-turn grounding (knowledge, memories, RULES, routing) goes in a
/// native tool turn. Measured 2026-09-05 on LFM2.5-1.2B (mlx-lm control, greedy,
/// 5 tool fixtures): grounding inside the USER turn ahead of the goal → 0/5 tool
/// calls, whatever the order or wording; the same text appended to the SYSTEM
/// turn → 5/5. The 4B tiers are indifferent, and their persona-prefix cache is
/// keyed on the system text, so they keep the user-turn layout. Per model,
/// decided by eval — not a global switch.
public enum NativePromptShape: Sendable, Equatable {
    /// Today's layout: system = persona; user = preamble + Context + Goal.
    case groundingInUser
    /// Small-model layout: system = persona + grounding; user = preamble + Goal.
    case groundingInSystem
}

/// Capability refinement: an `InferenceProvider` that speaks its model's NATIVE
/// tool-call dialect. `LocalAgent` runs the structured loop when the active
/// provider conforms; otherwise the prompt-ReAct floor.
public protocol ToolCallingProvider: InferenceProvider {
    /// Whether the BACKING MODEL can actually emit parseable tool calls right
    /// now — a RUNTIME answer, not type conformance. A swappable provider whose
    /// current model lacks tool support (or whose dialect isn't wired) reports
    /// `false` so the agent uses the ReAct floor instead of burning iterations
    /// on a model that will never call a tool.
    var supportsToolCalls: Bool { get }

    /// How the agent should lay out grounding for THIS model (see
    /// `NativePromptShape`). Defaults to the cached-tier layout.
    var nativePromptShape: NativePromptShape { get }

    /// Continue the conversation: given the transcript so far and the available
    /// tools, return the model's next turn (final text, or tool calls to run).
    func continueToolTurn(messages: [ToolMessage], tools: [ToolDefinition]) async throws -> ToolTurn

    /// Open a session for one agent turn. The default adapter re-renders the
    /// whole transcript through `continueToolTurn` per send (behaviourally
    /// identical to the pre-session loop); providers with real session state
    /// (a KV cache) override to make iteration ≥2 prefill only the delta.
    func makeToolTurnSession(
        tools: [ToolDefinition],
        options: ToolTurnOptions
    ) async throws -> any ToolTurnSession
}

public extension ToolCallingProvider {
    /// Defaults to FALSE — the safe direction. A conformer that forgets to
    /// override stays on the ReAct floor (which works for every model) instead
    /// of silently running a native loop whose calls never parse, burning all
    /// iterations with no safety net. Real providers override with a runtime
    /// answer (MLX: dialect recognised; wrappers: forward to the active backend).
    /// NOTE this flipped from `true` (PR #16 review): conformers MUST override
    /// to opt into the native loop — the default is a floor, not a hint.
    var supportsToolCalls: Bool {
        false
    }

    var nativePromptShape: NativePromptShape {
        .groundingInUser
    }

    func makeToolTurnSession(
        tools: [ToolDefinition],
        options _: ToolTurnOptions
    ) async throws -> any ToolTurnSession {
        StatelessToolTurnSession(provider: self, tools: tools)
    }

    /// Convenience: default options.
    func makeToolTurnSession(tools: [ToolDefinition]) async throws -> any ToolTurnSession {
        try await makeToolTurnSession(tools: tools, options: .default)
    }
}

/// The default session: tracks the transcript internally and re-renders the
/// whole of it through `continueToolTurn` each send — no cache, no behaviour
/// change from the pre-session loop. `@unchecked Sendable`: the transcript is
/// Mutex-guarded; the agent loop uses a session strictly serially anyway.
///
/// The re-render makes iteration N's prefill O(transcript) — fine at today's
/// iteration caps. TODO: profile TTFT here when a non-MLX provider (AFM tool
/// bridge, Phase 12b) starts carrying real agent turns.
final class StatelessToolTurnSession: ToolTurnSession, @unchecked Sendable {
    private let provider: any ToolCallingProvider
    private let tools: [ToolDefinition]
    private let transcript = Mutex<[ToolMessage]>([])

    init(provider: any ToolCallingProvider, tools: [ToolDefinition]) {
        self.provider = provider
        self.tools = tools
    }

    func send(
        _ messages: [ToolMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> ToolTurn {
        let snapshot = transcript.withLock { current in
            current.append(contentsOf: messages)
            return current
        }
        let turn = try await provider.continueToolTurn(messages: snapshot, tools: tools)
        switch turn {
        case let .text(answer):
            transcript.withLock { $0.append(.assistant(text: answer, toolCalls: [])) }
            if !answer.isEmpty { onToken(answer) }
        case let .toolCalls(calls):
            transcript.withLock { $0.append(.assistant(text: nil, toolCalls: calls)) }
        }
        return turn
    }
}

/// Accumulates a tool turn's FULL conversation — every message sent to the
/// model plus every turn it generated — so a session can re-render the whole
/// thing into a fresh cache when delta-rendering fails. Some chat templates
/// re-validate the entire message array on every render and reject a
/// tool-result-only delta (Qwen3.5: "No user query found in messages"); the
/// full transcript always carries the user query and the assistant tool-call
/// turns, so a clean re-render succeeds. Pure + ordered: the sent-then-
/// generated interleaving must reproduce a valid conversation.
public struct ToolTurnTranscript: Sendable {
    public private(set) var full: [ToolMessage] = []

    public init() {}

    /// The messages the agent just sent (recorded RAW — `.system` included, so
    /// a fresh re-render gets the persona back even when the delta path drops it).
    public mutating func recordSent(_ messages: [ToolMessage]) {
        full.append(contentsOf: messages)
    }

    /// The turn the model just produced, as the assistant message that turn
    /// represents — so the next re-render shows the model its own prior calls.
    public mutating func recordGenerated(_ turn: ToolTurn) {
        switch turn {
        case let .text(answer):
            full.append(.assistant(text: answer, toolCalls: []))
        case let .toolCalls(calls):
            full.append(.assistant(text: nil, toolCalls: calls))
        }
    }
}
