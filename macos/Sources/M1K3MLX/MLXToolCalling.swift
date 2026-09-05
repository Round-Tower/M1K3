//
//  MLXToolCalling.swift
//  M1K3MLX
//
//  Phase 12c — makes MLXGemmaProvider a `ToolCallingProvider`, so M1K3's main
//  on-device brain calls tools in its model's NATIVE dialect instead of the
//  prompt-ReAct floor. mlx-swift-lm 2.30.6 already parses the output for us
//  (ToolCallProcessor + per-dialect parsers emit `.toolCall(ToolCall)` inline
//  off the `Generation` stream); this file is the WIRING + type mapping between
//  the dialect-free seam (M1K3Inference) and the library's types — NOT a parser.
//
//  Model-agnostic by design (Kev's "support all brain types"): the dialect is
//  resolved per model family (Gemma → .gemma, Qwen/Llama → .json), the OUTPUT
//  parsing is the library's job for every family, and the only family-specific
//  code here is echoing the assistant's prior call back in its own syntax.
//
//  The pure mappers below are unit-tested (no Metal). `continueToolTurn` runs
//  the real model and is VERIFY-BY-LAUNCH — MLX needs the app-bundle metallib,
//  so it can't execute under `swift test` (same limit as all MLX generation).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-10, Confidence 0.75 (pure mappers
//  tested; the generation glue is verify-by-launch). Prior: Unknown.
//  Review: Kev + claude-fable-5, 2026-06-11, Confidence 0.85 — PR #16/#17
//  review follow-ups: nil-dialect now guard-throws (was a silent .gemma
//  fallback) in continueToolTurn + makeToolTurnSession; serial-use contract
//  comments extended to finish() and the non-seeded fallback path.
//  Review: Kev + claude-fable-5, 2026-07-12, Confidence 0.9 — the launch-time
//  persona-prefix warm (PR #27): public warmPersonaPrefix(tools:) + the shared
//  prefixInputs derivation, which sorts tools CANONICALLY by name — the quality
//  review caught that an unsorted warm rendered the tools JSON differently than
//  the live turn (LocalAgent sorts), colliding on the same cache key with
//  different KV content. Measured win ~1.9 s lil / ~3.3 s big (SelfTest
//  PREFIXWARM modes 1–3; mode 3 is the out-of-order tool-path proof).
//  Review: Kev + claude-fable-5, 2026-07-15, Confidence 0.9 — Ternary-Bonsai-8B
//  added to the .json arm by EXACT size id (config model_type "qwen3" +
//  <tool_call> template verified against HF; the Qwen3.6-based 27B deliberately
//  stays nil → ReAct floor). Live-proven same day: CHATEVAL tool-use 5/5 native.
//  Review: Kev + claude-fable-5, 2026-07-20, Confidence 0.8 — added
//  `seedPrefixTokenCount(tools:)`, the measurement seam PromptSizeStage uses to
//  size the persona+tool-spec KV-seed for a native (Big) turn — the chunk a
//  code-review bot found missing entirely from the flat-prompt instrument
//  (the seed is never a `prompt: String`, so nothing there could have counted
//  it). Thin reuse of `personaPrefixSnapshot`/`prefixInputs`, no new render
//  path; untested by design, same as its sibling `tokenCount`/
//  `templatedTokenCount` (Metal-backed, verify-by-launch — see M1K3MLXTests'
//  PersonaPrefixCacheTests, which tests only the pure cache-key half).

import Foundation
import M1K3Inference
import MLX
import MLXLMCommon
import os
import Synchronization

private let mlxToolLog = Logger(subsystem: "app.m1k3", category: "mlx-load")

/// Pure, testable bridges between the M1K3 tool-calling seam and mlx-swift-lm.
enum MLXToolMapping {
    /// Project a dialect-free `ToolDefinition` into the JSON-schema `ToolSpec`
    /// the model's chat template renders (same shape as the library's `Tool`
    /// initializer builds).
    /// The (specs, toolNames) pair that keys the persona-prefix KV cache —
    /// ONE derivation shared by `makeToolTurnSession` (the live turn) and
    /// `warmPersonaPrefix` (the launch warm), so the warmed cache entry is
    /// byte-identical to the key the first turn asks for. Empty tools → nil
    /// specs (the bare-persona key the plain-chat path uses).
    ///
    /// CANONICAL ORDER: sorted by tool name, HERE, regardless of what callers
    /// pass. The live agent path arrives pre-sorted (LocalAgent+Native sorts
    /// its Dictionary values) but the launch warm arrives in tool-builder
    /// insertion order — without one canonical order at this choke point, the
    /// warmed KV renders the tools JSON differently than the turn re-renders
    /// it, the cross-turn common-prefix scan diverges right at the tools
    /// block, and the warm buys nothing (the exact "tool-JSON ordering drift"
    /// class LocalAgent+Native's own comment warns about). Tools resolve by
    /// name; order is behaviourally irrelevant to the model.
    static func prefixInputs(for tools: [ToolDefinition]) -> (specs: [ToolSpec]?, toolNames: [String]) {
        let ordered = tools.sorted { $0.name < $1.name }
        let specs = ordered.map(toolSpec(from:))
        return (specs.isEmpty ? nil : specs, ordered.map(\.name))
    }

    static func toolSpec(from definition: ToolDefinition) -> ToolSpec {
        var properties: [String: any Sendable] = [:]
        var required: [String] = []
        for parameter in definition.parameters {
            properties[parameter.name] = [
                "type": parameter.type,
                "description": parameter.description,
            ] as [String: any Sendable]
            if parameter.isRequired { required.append(parameter.name) }
        }
        return [
            "type": "function",
            "function": [
                "name": definition.name,
                "description": definition.description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }

    /// Map one transcript turn to a `Chat.Message`. Tool results become the
    /// `.tool` role; an assistant turn that made calls echoes them back in the
    /// model's own dialect so the model sees its prior calls in trained form.
    static func chatMessage(
        from message: ToolMessage, format: ToolCallFormat = .gemma, imagesAllowed: Bool = false
    ) -> Chat.Message {
        switch message {
        case let .system(text):
            return .system(text)
        case let .user(text, images):
            // Images flow ONLY when the backing model is vision-capable
            // (VLM-loaded gemma-4-12B) — a text-only checkpoint's processor
            // would choke on (or silently mangle) image parts. Default false
            // keeps every pre-vision call site byte-identical.
            guard imagesAllowed, !images.isEmpty else { return .user(text) }
            return .user(text, images: images.map { .url($0.url) })
        case let .toolResult(_, output):
            // The library's Chat.Message.tool takes only the output text; the
            // model correlates result-to-call by turn order (one result per
            // call, in sequence). Revisit if multi-call round-trips ever need
            // the name for correlation.
            return .tool(output)
        case let .assistant(text, calls):
            guard !calls.isEmpty else { return .assistant(text ?? "") }
            let renderedCalls = calls.map { callText($0, format: format) }.joined(separator: "\n")
            let content = [text, renderedCalls]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return .assistant(content)
        }
    }

    /// Render a parsed call back into the model's native call syntax.
    static func callText(_ call: ParsedToolCall, format: ToolCallFormat) -> String {
        switch format {
        case .gemma: gemmaCallText(call)
        case .gemma4: gemma4CallText(call)
        case .xmlFunction: xmlFunctionCallText(call)
        default: jsonCallText(call)
        }
    }

    /// Gemma 3 dialect: `<start_function_call>call:name{k:value,k:<escape>str<escape>}<end_function_call>`
    /// — string args are escape-wrapped, scalars raw (mirrors GemmaFunctionParser).
    static func gemmaCallText(_ call: ParsedToolCall) -> String {
        gemmaStyleCallText(
            call, startTag: "<start_function_call>", endTag: "<end_function_call>", escapeMarker: "<escape>"
        )
    }

    /// Gemma 4 dialect: `<|tool_call>call:name{k:value,k:<|"|>str<|"|>}<tool_call|>` — Gemma 4
    /// changed BOTH the delimiters and the escape marker from Gemma 3. Mirrors upstream's
    /// `GemmaFunctionParser(.gemma4)` config (ToolCallFormat.createParser in mlx-swift-lm).
    static func gemma4CallText(_ call: ParsedToolCall) -> String {
        gemmaStyleCallText(
            call, startTag: "<|tool_call>", endTag: "<tool_call|>", escapeMarker: "<|\"|>"
        )
    }

    /// Shared Gemma-family call echo, parameterised by the dialect's delimiters +
    /// escape marker (string args escape-wrapped, scalars raw, keys sorted) — the
    /// single algorithm both Gemma 3 and Gemma 4 use, exactly as upstream configures
    /// one `GemmaFunctionParser` per format. Array/object arg VALUES fall back to
    /// `JSONValue.stringValue`: the Gemma dialect (and its upstream parser) handles
    /// only primitives + escaped strings, not nested structured args — true of both.
    private static func gemmaStyleCallText(
        _ call: ParsedToolCall, startTag: String, endTag: String, escapeMarker: String
    ) -> String {
        let arguments = call.arguments
            .sorted { $0.key < $1.key }
            .map { key, value -> String in
                if case let .string(string) = value {
                    return "\(key):\(escapeMarker)\(string)\(escapeMarker)"
                }
                return "\(key):\(value.stringValue)"
            }
            .joined(separator: ",")
        return "\(startTag)call:\(call.name){\(arguments)}\(endTag)"
    }

    /// XML function dialect (Qwen3.5/Nemotron):
    /// `<function=name><parameter=key>value</parameter></function>`
    /// (mirrors the library's XMLFunctionParser pattern).
    static func xmlFunctionCallText(_ call: ParsedToolCall) -> String {
        let parameters = call.arguments
            .sorted { $0.key < $1.key }
            .map { key, value -> String in
                let rendered: String = if case let .string(string) = value {
                    string
                } else {
                    value.stringValue
                }
                return "<parameter=\(key)>\(rendered)</parameter>"
            }
            .joined()
        return "<function=\(call.name)>\(parameters)</function>"
    }

    /// JSON dialect (Qwen/Llama/most): `<tool_call>{"name":…,"arguments":{…}}</tool_call>`.
    static func jsonCallText(_ call: ParsedToolCall) -> String {
        let payload = WireCall(name: call.name, arguments: call.arguments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return "<tool_call>{\"name\":\"\(call.name)\"}</tool_call>"
        }
        return "<tool_call>\(json)</tool_call>"
    }

    /// Map the library's parsed `ToolCall` to our dialect-free `ParsedToolCall`.
    static func parsedToolCall(from call: MLXLMCommon.ToolCall) -> ParsedToolCall {
        ParsedToolCall(
            name: call.function.name,
            arguments: call.function.arguments.mapValues(jsonValue(from:))
        )
    }

    /// Convert the library's `JSONValue` to ours (identical case sets).
    static func jsonValue(from value: MLXLMCommon.JSONValue) -> M1K3Inference.JSONValue {
        switch value {
        case .null: .null
        case let .bool(bool): .bool(bool)
        case let .int(int): .int(int)
        case let .double(double): .double(double)
        case let .string(string): .string(string)
        case let .array(array): .array(array.map(jsonValue(from:)))
        case let .object(object): .object(object.mapValues(jsonValue(from:)))
        }
    }

    /// Codable shape for serialising a call to the JSON dialect.
    private struct WireCall: Codable {
        let name: String
        let arguments: [String: M1K3Inference.JSONValue]
    }
}

// MARK: - ToolCallingProvider conformance

extension MLXGemmaProvider: ToolCallingProvider {
    /// Resolve a model's native tool-call dialect from its identifier. Explicit
    /// configuration wins; otherwise the model family decides. `nil` means we
    /// don't recognise the family → the agent falls back to the ReAct floor
    /// rather than running a native loop that will never parse a call.
    ///
    /// `modelType` is config.json's `model_type` when the repo is already on
    /// disk (`LocalModelConfig`). It decides FIRST: the architecture names the
    /// dialect regardless of what the repo is called — "Qwen3.8-27B" is
    /// model_type qwen3_5 and speaks XML functions, but the name arm alone
    /// read "qwen" and picked JSON, which degrades tool-use to 0/5 silently.
    /// An unknown type falls through to the name heuristic (never to nil).
    static func resolveToolCallFormat(
        for configuration: ModelConfiguration, modelType: String? = nil
    ) -> ToolCallFormat? {
        if let explicit = configuration.toolCallFormat { return explicit }
        if let byType = modelType.flatMap(toolCallFormat(forModelType:)) { return byType }
        let name = configuration.name.lowercased()
        // Gemma 4 emits a NEW dialect (<|tool_call>…<tool_call|>, escape <|"|>) parsed by
        // upstream's GemmaFunctionParser(.gemma4) — available since #183 now that we build
        // off mlx-swift-lm main (see Package.swift). Routes NATIVE instead of the ReAct
        // floor that left gemma-4 reasoning into silence. MUST stay before the generic
        // gemma arm (gemma3n contains "gemma" but not "gemma4" → still .gemma).
        if name.contains("gemma-4") || name.contains("gemma4") { return .gemma4 }
        if name.contains("gemma") { return .gemma }
        // Qwen3.5 is trained on the XML function dialect, NOT <tool_call> JSON
        // (matches upstream infer(): qwen3_5 → .xmlFunction). Bonsai-27B is
        // qwen3_5 under a brand id — config model_type + the <function=…>
        // <parameter=…> template verified against HF 2026-07-17, the
        // re-verification the old nil pin demanded. Exact size id: the 8B is
        // dense Qwen3 and rides the .json arm below.
        // Qwen3.8 (Aug 2026) is the same qwen3_5 family under a new number —
        // config verified 2026-09-05. Listed by name for the pre-download case;
        // once config.json is on disk the model_type arm above owns it.
        if name.contains("qwen3.5") || name.contains("qwen3_5") || name.contains("qwen3-5")
            || name.contains("qwen3.8") || name.contains("ternary-bonsai-27b")
        {
            return .xmlFunction
        }
        // prism-ml's Ternary-Bonsai-8B is Qwen3 QAT under a brand id (no "qwen"
        // substring; verified 2026-07-15: model_type "qwen3", <tool_call> JSON
        // template). Matched by EXACT size id — the 27B is a different family
        // (qwen3_5) and resolves to .xmlFunction in the arm above; any future
        // Bonsai size extends per size only with its config + template
        // re-verified.
        if name.contains("qwen") || name.contains("llama") || name.contains("ternary-bonsai-8b")
            || name.contains("mistral") || name.contains("phi") { return .json }
        if name.contains("glm") { return .glm4 }
        if name.contains("lfm2") { return .lfm2 }
        return nil
    }

    /// The dialect by architecture (`config.json` model_type), for the families
    /// whose template we have verified. Mirrors upstream's registry names
    /// (`LLMModelFactory` / `VLMModelFactory` keys); a type not listed here
    /// returns nil so the caller falls back to the name heuristic.
    static func toolCallFormat(forModelType modelType: String) -> ToolCallFormat? {
        let type = modelType.lowercased()
        if type.hasPrefix("gemma4") { return .gemma4 }
        if type.hasPrefix("gemma3") || type == "gemma" || type == "gemma2" { return .gemma }
        // qwen3_next is NOT listed: same SSM/hybrid lineage, but its tool template is
        // unverified — add it only with the config + chat_template check the other arms carry.
        if type.hasPrefix("qwen3_5") { return .xmlFunction }
        if type == "qwen3" || type == "qwen3_moe" || type == "qwen2" || type == "llama" || type == "phi3"
            || type == "mistral" || type == "mistral3" { return .json }
        if type.hasPrefix("glm4") { return .glm4 }
        if type.hasPrefix("lfm2") { return .lfm2 }
        return nil
    }

    /// True only when the model family has a known dialect — defuses the silent
    /// `.json` fallback trap (a model we can't parse would loop to the cap with
    /// none of the ReAct safety nets).
    public var supportsToolCalls: Bool {
        resolvedToolCallFormat != nil
    }

    /// Run one model turn over the transcript + tools, returning structure. The
    /// library parses the model's native dialect into `.toolCall` events inline;
    /// we collect them (and any free text) into a `ToolTurn`. Stateless-renders-
    /// array: the whole transcript is re-rendered each call so the agent keeps
    /// owning it (for the trace + observation rescue), per the 12a challenger pass.
    public func continueToolTurn(messages: [ToolMessage], tools: [ToolDefinition]) async throws -> ToolTurn {
        let container = try await ensureLoaded()
        // Unreachable via LocalAgent (supportsToolCalls == false gates this
        // path for an unrecognised family), but this is public API — throwing
        // beats silently rendering the wrong dialect and never parsing a call.
        guard let format = resolvedToolCallFormat else {
            throw InferenceError.generationFailed(
                "no tool-call dialect resolved for this model family"
            )
        }
        let parameters = generateParameters
        let prefixNeeded = thinkPrefixNeeded
        let thinkingContext = thinkingAdditionalContext
        // An agent turn runs several generations back-to-back; reclaim after
        // each so their peaks don't compound in the process-global MLX cache.
        defer { MLXMemoryBudget.reclaim(label: "toolTurn") }

        return try await container.perform { context in
            let chat = messages.map { MLXToolMapping.chatMessage(from: $0, format: format) }
            let specs = tools.map(MLXToolMapping.toolSpec(from:))
            let userInput = UserInput(
                chat: chat,
                tools: specs.isEmpty ? nil : specs,
                additionalContext: thinkingContext
            )
            let input = try await context.processor.prepare(input: userInput)

            let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
            var text = ""
            var calls: [ParsedToolCall] = []
            for await event in stream {
                switch event {
                case let .chunk(piece):
                    text += piece
                case let .toolCall(libraryCall):
                    calls.append(MLXToolMapping.parsedToolCall(from: libraryCall))
                case let .info(info):
                    logGenerationInfo(info, label: "toolTurn", model: modelIdentifier)
                @unknown default:
                    break
                }
            }
            if calls.isEmpty {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return ToolTurn.text(Self.normaliseThinkPrefix(trimmed, preOpened: prefixNeeded))
            }
            return ToolTurn.toolCalls(calls)
        }
    }

    /// The REAL session: one KV cache for the whole agent turn. Iteration ≥2
    /// renders and prefills only the new tool-result messages — the prompt,
    /// grounding, tool specs, and every prior generation are already in the
    /// cache (upstream ChatSession's delta-render pattern, with our loop in
    /// control).
    /// Pre-build the persona-prefix KV for `tools` so the FIRST turn starts
    /// from a cached copy instead of paying the build on its critical path.
    /// Measured 2026-07-12 (SelfTest PREFIXWARM, 2 runs/tier): the build costs
    /// ~1.9 s on lil and ~3.3 s on big — measured on the SLOT-HOLDERS AT THE
    /// TIME (lil: Qwen3-4B; big: gemma-4-e4b). Both slots have since moved
    /// (lil→Instruct-2507 2026-07-16, big→gemma-4-12B 2026-07-15) and are
    /// unmeasured here — re-run PREFIXWARM to refresh; a warm turn's first
    /// token lands in ~150–190 ms. Best-effort and idempotent: any
    /// failure just logs — the turn falls back to building inline, exactly the
    /// pre-warm behavior. Key parity with the live turn is structural: both
    /// route through `MLXToolMapping.prefixInputs` (pinned in tests). A turn
    /// racing the warm queues behind it on the ModelContainer — worst case it
    /// pays the build it would have paid anyway.
    public func warmPersonaPrefix(tools: [ToolDefinition]) async {
        do {
            let container = try await ensureLoaded()
            let inputs = MLXToolMapping.prefixInputs(for: tools)
            let seed = try await buildPersonaPrefixSnapshot(
                container: container,
                specs: inputs.specs,
                toolNames: inputs.toolNames
            )
            if let seed {
                let model = modelIdentifier
                mlxToolLog.notice(
                    "persona prefix warmed [\(model, privacy: .public)]: \(seed.tokenIDs.count) tokens, \(tools.count) tool(s)"
                )
            }
        } catch {
            let model = modelIdentifier
            mlxToolLog.notice(
                "persona prefix warm skipped [\(model, privacy: .public)]: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// The exact token cost of the persona+tool-spec KV-seed for `tools` — what
    /// `makeToolTurnSession` prefills ONCE per (model × tools × persona),
    /// before a single per-turn token is sent. This is the measurement seam
    /// for the prompt-size instrument (PromptSizeStage): the seed is never
    /// rendered as a flat prompt string, so it can't be counted by splitting
    /// one — but it IS available without running a generation. Reuses
    /// `personaPrefixSnapshot`/`MLXToolMapping.prefixInputs`, the same
    /// derivation `warmPersonaPrefix` and the live turn use, so this can't
    /// drift from what the model actually saw. `nil` when the prefix can't be
    /// built (best-effort, same contract as `personaPrefixSnapshot`) — never a
    /// confident zero.
    public func seedPrefixTokenCount(tools: [ToolDefinition]) async -> Int? {
        do {
            let container = try await ensureLoaded()
            let inputs = MLXToolMapping.prefixInputs(for: tools)
            guard let seed = await personaPrefixSnapshot(
                container: container, specs: inputs.specs, toolNames: inputs.toolNames
            ) else { return nil }
            return seed.tokenCount
        } catch {
            return nil
        }
    }

    public func makeToolTurnSession(
        tools: [ToolDefinition],
        options: ToolTurnOptions
    ) async throws -> any ToolTurnSession {
        // Same gate as continueToolTurn: an unrecognised family must not get
        // a session that renders the wrong dialect.
        guard let format = resolvedToolCallFormat else {
            throw InferenceError.generationFailed(
                "no tool-call dialect resolved for this model family"
            )
        }
        let container = try await ensureLoaded()
        // Persona (and tools — they render in the SAME system block) prefilled
        // once per (model × tools × persona); this turn starts from a copy.
        // prefixInputs is the SHARED key derivation with warmPersonaPrefix —
        // don't inline it here or the launch warm drifts off this key.
        // (enable_thinking only touches the generation suffix, template-probe
        // verified — the cached prefix is identical either way.)
        let inputs = MLXToolMapping.prefixInputs(for: tools)
        // Conversation tail first, persona fallback — the tail always BEGINS
        // with the persona render (same key), so it can only ever reuse more,
        // and any divergence fails soft through the common-prefix arithmetic.
        // Background utilities skip the tail both ways for the same reason
        // they never BUILD a persona prefix: a title turn's render would
        // produce a useless tail, and adopting it would displace the live
        // conversation's seed.
        let key = toolTurnCacheKey(toolNames: inputs.toolNames)
        let background = InferenceIntent.isBackgroundUtility
        let seed: PersonaPrefixSnapshot?
        let seedSource: PrefixSeedSource
        if !background, let tail = conversationTail.snapshot(for: key) {
            seed = tail
            seedSource = .conversation
        } else {
            seed = await personaPrefixSnapshot(
                container: container,
                specs: inputs.specs,
                toolNames: inputs.toolNames,
                key: key
            )
            seedSource = seed == nil ? .none : .persona
        }
        let adoptTail: (([KVCache], [Int]) -> ConversationTailCache.AdoptOutcome)? = background
            ? nil
            : { [conversationTail] cache, ids in
                conversationTail.adopt(cache, tokenIDs: ids, for: key)
            }
        // Per-turn thinking, decided ONLY from this turn's flag + the family's
        // toggle capability — never the provider's construction-time thinking
        // state (which would silently override a turn that asked to think).
        let thinking = Self.toolTurnThinkingDecision(
            turnThinking: options.thinkingEnabled,
            supportsToggle: supportsThinkingToggle,
            preOpensThink: preOpensThinkTemplate
        )
        return MLXToolTurnSession(
            container: container,
            modelID: modelIdentifier,
            parameters: generateParameters,
            format: format,
            specs: inputs.specs,
            thinkingContext: thinking.context,
            prefixNeeded: thinking.prefixNeeded,
            imagesAllowed: supportsImageInput,
            seed: seed,
            seedSource: seedSource,
            adoptTail: adoptTail
        )
    }

    /// Per-turn thinking decision (pure). `supportsToggle` (does the family read
    /// `enable_thinking`?) gates suppression; `preOpensThink` (does the template
    /// pre-open `<think>`? — Qwen3.5 only) gates the synthetic opener. These are
    /// SEPARATE: dense Qwen3 toggles thinking but does NOT pre-open, so a fast turn
    /// suppresses (`enable_thinking:false`) while a thinking turn adds no opener
    /// (the model emits its own). Independent of construction-time `thinkingEnabled`
    /// so the in-turn decision wins.
    static func toolTurnThinkingDecision(
        turnThinking: Bool,
        supportsToggle: Bool,
        preOpensThink: Bool
    ) -> (context: [String: any Sendable]?, prefixNeeded: Bool) {
        let suppressThinking = supportsToggle && !turnThinking
        return (
            suppressThinking ? ["enable_thinking": false] : nil,
            turnThinking && preOpensThink
        )
    }
}

/// Per-turn MLX session: a live `[KVCache]` shared across the turn's
/// generations. `@unchecked Sendable`: the agent loop sends strictly serially,
/// state hands off through a Mutex, and the cache arrays are evaluated by the
/// generation loop before the next send (the same cross-isolation contract
/// upstream ChatSession relies on).
final class MLXToolTurnSession: ToolTurnSession, @unchecked Sendable {
    private let container: ModelContainer
    private let modelID: String
    private let parameters: GenerateParameters
    private let format: ToolCallFormat
    private let specs: [ToolSpec]?
    private let thinkingContext: [String: any Sendable]?
    private let prefixNeeded: Bool
    /// Whether this session's model consumes attached images (VLM-loaded).
    /// False drops images at the chat mapping — text renders identically.
    private let imagesAllowed: Bool

    /// Serial-use contract (why @unchecked is sound): `LocalAgent` is an
    /// actor and `runNativeLoop` awaits each `send` — and calls `finish()`
    /// only after the loop returns — so these are only ever touched one call
    /// at a time, inside `container.perform`'s isolation. The actor enforces
    /// what the compiler can't check here. A Mutex can't hold a non-Sendable
    /// KVCache without tripping region isolation on the way out.
    private var kvCache: [KVCache]?
    /// An EXACT mirror of the token sequence the live cache holds, so a
    /// token-level common prefix against the next render is positionally-valid
    /// KV. Seeded from the persona prefix; kept in sync on every send (trim the
    /// generated tail, set to the rendered fullIDs). The whole reuse scheme
    /// rests on this staying truthful — see CrossTurnCacheReuse.
    private var cachedIDs: [Int]
    /// Sends so far this session — the first send is the one whose reuse SHOULD
    /// equal the seeded persona prefix, so a shortfall there is a diagnosable
    /// seed/render mismatch (logged, decoded).
    private var sendCount = 0
    /// Where the seed came from — printed in the reuse log so a working
    /// conversation tail is distinguishable from a warm persona prefix.
    private let seedSource: PrefixSeedSource
    /// Hand-off for the end-of-turn cache (nil = drop, today's behaviour).
    /// Installed by the provider for interactive turns only.
    private let adoptTail: (([KVCache], [Int]) -> ConversationTailCache.AdoptOutcome)?
    /// The full conversation — re-rendered every turn so strict templates
    /// (Qwen3.5's "No user query found") always see the user query; only the
    /// suffix beyond `cachedIDs` is actually prefilled.
    private var transcript = ToolTurnTranscript()

    init(
        container: ModelContainer,
        modelID: String,
        parameters: GenerateParameters,
        format: ToolCallFormat,
        specs: [ToolSpec]?,
        thinkingContext: [String: any Sendable]?,
        prefixNeeded: Bool,
        imagesAllowed: Bool = false,
        seed: PersonaPrefixSnapshot? = nil,
        seedSource: PrefixSeedSource = .none,
        adoptTail: (([KVCache], [Int]) -> ConversationTailCache.AdoptOutcome)? = nil
    ) {
        self.container = container
        self.modelID = modelID
        self.parameters = parameters
        self.format = format
        self.specs = specs
        self.thinkingContext = thinkingContext
        self.prefixNeeded = prefixNeeded
        self.imagesAllowed = imagesAllowed
        self.seedSource = seedSource
        self.adoptTail = adoptTail
        kvCache = seed?.cache
        cachedIDs = seed?.tokenIDs ?? []
    }

    func send(
        _ messages: [ToolMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> ToolTurn {
        let format = format
        let parameters = parameters
        let prefixNeeded = prefixNeeded
        let thinkingContext = thinkingContext
        // Qwen3.5's template pre-opens <think> — surface the opener so live
        // splitting engages from the generation's first real token.
        if prefixNeeded { onToken("<think>") }

        return try await container.perform { context in
            self.transcript.recordSent(messages)

            // Render the WHOLE conversation (system + goal + every assistant
            // call + every tool result). A full array always carries the user
            // query, so strict templates never reject it — but we prefill only
            // the suffix past what the live cache already holds.
            let imagesAllowed = self.imagesAllowed
            let fullChat = self.transcript.full.map {
                MLXToolMapping.chatMessage(from: $0, format: format, imagesAllowed: imagesAllowed)
            }
            let prepared = try await context.processor.prepare(
                input: UserInput(chat: fullChat, tools: self.specs, additionalContext: thinkingContext)
            )
            let fullIDs = prepared.text.tokens.asArray(Int.self)

            // An image anywhere in the render vetoes the suffix fast path:
            // slicing to raw token ids would drop the pixels (LMInput.image
            // rides beside the tokens with absolute position ids). The full
            // prepared input prefills on a fresh cache instead — correct,
            // just re-prefills the persona. (Also true on iteration 2+ of an
            // image turn: the image re-encodes each iteration. Optimization
            // follow-up, not a correctness issue.)
            let turnCarriesImages = imagesAllowed
                && self.transcript.full.contains {
                    if case let .user(_, images) = $0 { return !images.isEmpty }
                    return false
                }

            let seedCount = self.cachedIDs.count
            let reuse = CrossTurnCacheReuse.suffixReuseAllowed(turnCarriesImages: turnCarriesImages)
                ? CrossTurnCacheReuse.reusableLength(
                    cached: self.cachedIDs, full: fullIDs, hasCache: self.kvCache != nil
                )
                : 0
            // Diagnose a first-send seed miss: the PERSONA prefix SHOULD be a
            // full prefix of the first render. If reuse falls short, decode the
            // tokens either side of the divergence so the cause is visible (a
            // tool-JSON ordering drift, a persona-text mismatch, …). Persona
            // seeds ONLY: a conversation tail legitimately falls short whenever
            // the grounding changed or the history window slid — that's the
            // fail-soft working as designed, not a mismatch to alarm on.
            if self.seedSource == .persona,
               self.sendCount == 0, seedCount > 0, reuse < seedCount, !turnCarriesImages
            {
                let window = { (ids: [Int]) -> String in
                    let lo = max(0, reuse - 3), hi = min(ids.count, reuse + 8)
                    return context.tokenizer.decode(tokenIds: Array(ids[lo ..< hi]))
                }
                self.logSeedReuseMiss(
                    at: reuse, of: seedCount, seed: window(self.cachedIDs), render: window(fullIDs)
                )
            }
            self.sendCount += 1
            let cache: [KVCache]
            let input: LMInput
            // Reuse only a LINEAR cache: trimming a wrapped sliding-window cache
            // (gemma-4's RotatingKVCache) underflows its rotation pointer and the
            // next decode asserts in temporalOrder. isTrimmable==false flags the
            // wrap; one wrapped layer vetoes reuse (rebuild fresh — correct, just
            // re-prefills the prefix).
            let reusable = CrossTurnCacheReuse.cacheReusable(
                layersTrimmable: self.kvCache?.map(\.isTrimmable) ?? []
            )
            // Keep the cachedIDs mirror truthful at EVERY throw point: if
            // generate() below throws (cancellation, model error) the end-of-
            // turn mirror update never runs, and a stale mirror against a
            // trimmed/fresh cache corrupts the NEXT turn's reuse computation —
            // a suffix-only prefill into a cache that doesn't hold the prefix.
            // If generate() throws AFTER partially prefilling, the mirror
            // UNDERSTATES the cache — safe: the next turn computes a shorter
            // reuse and trims against layer.offset (the cache's real state).
            // Only an OVERSTATED mirror corrupts, and no path produces one.
            if reuse > 0, reusable, let existing = self.kvCache {
                // Keep the reusable prefix; trim past it (the prior turn's
                // generated tail + any divergence) and prefill only the rest.
                for layer in existing {
                    let extra = layer.offset - reuse
                    if extra > 0 { _ = layer.trim(extra) }
                }
                cache = existing
                self.cachedIDs = Array(fullIDs[..<reuse])
                input = LMInput(tokens: MLXArray(Array(fullIDs[reuse...])))
            } else {
                cache = context.model.newCache(parameters: parameters)
                self.cachedIDs = []
                input = prepared
            }
            // Report what was APPLIED, not what was computed. Until 2026-08-09
            // this logged the common-prefix length whether or not reuse
            // survived the `reusable` veto — so on gemma-4, where a 1024-token
            // sliding window means the cache wraps on every real turn and reuse
            // is ALWAYS vetoed, it cheerfully reported "1776/2750 from cache"
            // while re-prefilling all 2750. An instrument that reports intent
            // as outcome hides the thing it exists to measure.
            self.logPrefillReuse(
                reused: (reuse > 0 && reusable) ? reuse : 0,
                total: fullIDs.count,
                vetoed: reuse > 0 && !reusable,
                source: self.seedSource.rawValue
            )
            self.kvCache = cache

            let stream = try MLXLMCommon.generate(
                input: input, cache: cache, parameters: parameters, context: context
            )
            var text = ""
            var calls: [ParsedToolCall] = []
            for await event in stream {
                switch event {
                case let .chunk(piece):
                    text += piece
                    onToken(piece)
                case let .toolCall(libraryCall):
                    calls.append(MLXToolMapping.parsedToolCall(from: libraryCall))
                case let .info(info):
                    // fullIDs.count = the whole rendered conversation — the true
                    // context for the readout; info's own count is suffix-only
                    // when the cache held a prefix.
                    logGenerationInfo(
                        info, label: "toolTurnSession", model: modelID,
                        totalContextTokens: fullIDs.count
                    )
                @unknown default:
                    break
                }
            }
            // Keep cachedIDs an EXACT mirror of the cache: trim this turn's
            // generated tokens (unstable — the next render re-derives the
            // assistant turn structurally), leaving precisely fullIDs in place.
            // But if a sliding-window layer WRAPPED during generation it can no
            // longer be trimmed into a faithful linear mirror (the same
            // RotatingKVCache underflow) — drop the cache so the next send
            // rebuilds fresh rather than reusing a corrupt one.
            if CrossTurnCacheReuse.cacheReusable(layersTrimmable: cache.map(\.isTrimmable)) {
                for layer in cache {
                    let extra = layer.offset - fullIDs.count
                    if extra > 0 { _ = layer.trim(extra) }
                }
                self.kvCache = cache
                self.cachedIDs = fullIDs
            } else {
                self.kvCache = nil
                self.cachedIDs = []
            }

            let turn: ToolTurn
            if calls.isEmpty {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                turn = .text(MLXGemmaProvider.normaliseThinkPrefix(trimmed, preOpened: prefixNeeded))
            } else {
                turn = .toolCalls(calls)
            }
            self.transcript.recordGenerated(turn)
            return turn
        }
    }

    /// Param-only (the Logger interpolation is an autoclosure; swiftformat
    /// strips the `self.` the compiler would need on a member).
    private func logPrefillReuse(reused: Int, total: Int, vetoed: Bool, source: String) {
        // `vetoed` is the interesting case and deserves its own word: the cache
        // HELD a usable prefix and the sliding window made it unusable.
        // `seed=` is the acceptance instrument for the conversation tail: a
        // reuse figure above the persona length with seed=persona would mean
        // the tail never engaged — the two must be distinguishable in the log.
        let note = vetoed ? " (VETOED — cache wrapped the sliding window)" : ""
        mlxToolLog.notice(
            """
            toolTurnSession reuse: \(reused, privacy: .public)/\(total, privacy: .public) \
            tok from cache, prefilling \(total - reused, privacy: .public), \
            seed=\(source, privacy: .public)\(note, privacy: .public)
            """
        )
    }

    /// First-send persona-prefix shortfall — the seed should be a full prefix
    /// of the first render; decode both sides of the divergence to show why.
    private func logSeedReuseMiss(at index: Int, of seed: Int, seed seedSlice: String, render: String) {
        mlxToolLog.error(
            "toolTurnSession seed-reuse miss: \(index, privacy: .public)/\(seed, privacy: .public) — diverges at seed=[\(seedSlice, privacy: .public)] render=[\(render, privacy: .public)]"
        )
    }

    /// Turn over: hand the cache to the conversation-tail slot (the next turn
    /// of this conversation seeds from it), then reclaim pooled buffers —
    /// the per-TURN reclaim (per-generation would thrash the pool between
    /// iterations that are about to reuse it). The bare `kvCache = nil` write
    /// is covered by the serial-use contract above: finish() is reachable
    /// only after runNativeLoop returns, never overlapping a `send`.
    ///
    /// Adoption guards: only a LINEAR cache is worth keeping — a wrapped
    /// sliding-window cache can't be trimmed to a common prefix (the same veto
    /// the send path applies), which is also the gemma-4 tier gate: its real
    /// turns wrap, so it never stores a tail. A throw-path finish (barge-in,
    /// cancellation) may hand over a cache whose mirror UNDERSTATES it — safe
    /// for the same reason the send path documents: the next turn's trim runs
    /// against `layer.offset`, the cache's real state. The adopted arrays are
    /// retained by the store, so the reclaim below can't free them.
    func finish() async {
        if let cache = kvCache, !cachedIDs.isEmpty, let adoptTail,
           CrossTurnCacheReuse.cacheReusable(layersTrimmable: cache.map(\.isTrimmable))
        {
            logTailAdoption(adoptTail(cache, cachedIDs), tokens: cachedIDs.count)
        }
        kvCache = nil
        MLXMemoryBudget.reclaim(label: "toolTurnSession")
    }

    /// Param-only for the same swiftformat/autoclosure reason as its sibling.
    private func logTailAdoption(_ outcome: ConversationTailCache.AdoptOutcome, tokens: Int) {
        switch outcome {
        case .stored:
            mlxToolLog.notice(
                "toolTurnSession tail adopted: \(tokens, privacy: .public) tok retained for the next turn"
            )
        case .overCap:
            // The eviction is LOUD on purpose (no silent caps): from here on,
            // this conversation re-prefills its history every turn again.
            mlxToolLog.notice(
                """
                toolTurnSession tail EVICTED: \(tokens, privacy: .public) tok over the \
                \(ConversationTailCache.maxSeedTokens, privacy: .public)-tok cap — next turn seeds from persona
                """
            )
        }
    }
}
