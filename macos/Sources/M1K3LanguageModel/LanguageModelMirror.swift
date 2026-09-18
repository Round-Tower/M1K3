//
//  LanguageModelMirror.swift
//  M1K3LanguageModel
//
//  A LOCAL MIRROR of Apple's WWDC26 `FoundationModels` surface (ADR 0001). Names
//  mirror Apple's so that, on the macOS 27 SDK, the conformance retargets to
//  `import FoundationModels` with near-mechanical edits. This file builds and runs
//  on macOS < 27 (Tahoe today) — it is M1K3's universal floor for the bridge.
//
//  Scope: this module is the PURE surface + the escalation policy. The real
//  executor (wrapping MLXBrainProvider + ThinkStreamGate) lands on M1K3Agent.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.85 (mirror shape proven
//  against AnyLanguageModel + WWDC26 339; retarget is mechanical). Prior: Unknown
//

import Foundation

/// What a model can do — mirrors Apple's `LanguageModelCapabilities`.
public struct LanguageModelCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let toolCalling = LanguageModelCapabilities(rawValue: 1 << 0)
    public static let reasoning = LanguageModelCapabilities(rawValue: 1 << 1)
    public static let vision = LanguageModelCapabilities(rawValue: 1 << 2)
    public static let guidedGeneration = LanguageModelCapabilities(rawValue: 1 << 3)
}

/// Privacy reach of a model — the axis M1K3's offline ethos hinges on. NOT an
/// Apple type; M1K3's own classification used to gate egress.
public enum Reach: String, Sendable, Hashable, CaseIterable {
    case onDevice = "on-device"
    case privateCloud = "private-cloud"
    case thirdParty = "third-party"

    /// True when using this model keeps everything on the user's machine.
    public var isOffline: Bool {
        self == .onDevice
    }
}

/// A registry-level description of a conforming model — enough for the ladder to
/// choose without constructing an executor. The concrete `LanguageModel`
/// conformance (with its executor) wraps one of these in M1K3Agent.
public struct LanguageModelDescriptor: Sendable, Hashable, Identifiable {
    public let id: String
    public let reach: Reach
    public let capabilities: LanguageModelCapabilities
    /// True for Apple's on-device `SystemLanguageModel` — only usable where the
    /// silicon supports Apple Intelligence.
    public let requiresAppleIntelligence: Bool
    /// True for M1K3's bundled MLX brain — the always-available offline floor.
    public let isLocalFloor: Bool

    public init(
        id: String,
        reach: Reach,
        capabilities: LanguageModelCapabilities,
        requiresAppleIntelligence: Bool = false,
        isLocalFloor: Bool = false
    ) {
        self.id = id
        self.reach = reach
        self.capabilities = capabilities
        self.requiresAppleIntelligence = requiresAppleIntelligence
        self.isLocalFloor = isLocalFloor
    }
}

// MARK: - The protocol shape (retargets to FoundationModels on macOS 27)

/// Mirrors Apple's `LanguageModel`: a describable model that vends an executor.
/// On the macOS 27 SDK this becomes a conformance to the real `LanguageModel`.
public protocol LanguageModelDescribing: Sendable {
    var descriptor: LanguageModelDescriptor { get }
    func makeExecutor() -> any LanguageModelExecuting
}

/// Mirrors `LanguageModelExecutor.respond(to:model:streamingInto:)`. The executor
/// is where M1K3 runs its tuned generate loop and routes tokens through
/// `ThinkStreamGate` before the channel — i.e. our value-add over a generic adapter.
public protocol LanguageModelExecuting: Sendable {
    func respond(to prompt: String, into channel: GenerationChannel) async throws
}

/// Mirrors `LanguageModelExecutorGenerationChannel`. Apple's surface has NO reasoning
/// segment (`Transcript.Segment` = .text/.structure/.image), so reasoning is routed
/// to M1K3's own sink here — keeping the answer stream clean (the `<think>` leak the
/// naive adapter suffers). See ADR 0001 + scratch spike `ThinkGateChannel.swift`.
///
/// Thread-safety: the mutable properties are UNSYNCHRONIZED. Callers MUST drive a
/// channel from a single concurrent context — `M1K3ModelExecutor.respond` creates a
/// fresh channel per turn and never shares it across tasks, which is what makes the
/// `@unchecked Sendable` conformance sound. The gate's `Mutex` guards the gate, NOT
/// this channel. Do not pass one channel across concurrent tasks.
public final class GenerationChannel: @unchecked Sendable {
    /// A tool the model asked to call — mirrors Apple's `.toolCallDelta`. Kept a
    /// plain string map so this module stays dependency-free; the executor maps
    /// M1K3's typed `ParsedToolCall` into one of these at the edge.
    public struct ToolCallEvent: Sendable, Equatable {
        public let name: String
        public let arguments: [String: String]
        public init(name: String, arguments: [String: String]) {
            self.name = name
            self.arguments = arguments
        }
    }

    public private(set) var answer = ""
    public private(set) var reasoning = ""
    public private(set) var toolCalls: [ToolCallEvent] = []
    public private(set) var inputTokenCount = 0

    public init() {}

    /// Answer text the session surfaces — maps to Apple's `.appendText`.
    public func appendText(_ text: String) {
        answer += text
    }

    /// Reasoning disclosure — M1K3-side; no protocol segment exists for it.
    public func appendReasoning(_ text: String) {
        reasoning += text
    }

    /// A requested tool call — maps to Apple's `.toolCallDelta`.
    public func appendToolCall(_ call: ToolCallEvent) {
        toolCalls.append(call)
    }

    /// Token accounting — maps to Apple's `.updateUsage`.
    public func updateUsage(inputTokens: Int) {
        inputTokenCount = inputTokens
    }
}
