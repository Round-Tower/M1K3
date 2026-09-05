//
//  MLXToolMappingTests.swift
//  M1K3MLXTests
//
//  Fast tier (no Metal, no model): the PURE mappers that bridge the dialect-free
//  ToolCallingProvider seam (M1K3Inference) to mlx-swift-lm's native types —
//  AgentTool definitions → ToolSpec JSON schema, the [ToolMessage] transcript →
//  [Chat.Message] (with Gemma call-text echoed on the assistant turn + tool-role
//  results), and the library's parsed ToolCall → our ParsedToolCall. The actual
//  generation loop (continueToolTurn) is verify-by-launch — MLX needs the app
//  bundle's metallib — so these mappers carry the regression coverage.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-10, Confidence 0.85, Prior: Unknown

import Foundation
import M1K3Inference
@testable import M1K3MLX
import MLXLMCommon
import Testing

struct MLXPrefixInputsTests {
    /// The (specs, toolNames) pair keys the persona-prefix KV cache. ONE
    /// derivation shared by makeToolTurnSession (the live turn) and
    /// warmPersonaPrefix (the launch warm) — these pins are what make "the
    /// warm builds the exact key the first turn asks for" a tested fact.
    private let tools = [
        ToolDefinition(
            name: "web_search", description: "Search the web.",
            parameters: [ToolParameterDefinition(name: "query", description: "the query")]
        ),
        ToolDefinition(
            name: "get_document", description: "Fetch a document.",
            parameters: [
                ToolParameterDefinition(name: "title", description: "the title"),
                ToolParameterDefinition(name: "offset", description: "resume offset", isRequired: false),
            ]
        ),
    ]

    @Test("tool order is CANONICAL (sorted by name) no matter what the caller passes")
    func orderIsCanonical() {
        // Declared web_search-first above; the derivation must sort. The live
        // agent path arrives pre-sorted, the launch warm arrives in builder
        // insertion order — this sort is what makes the two render the SAME
        // tools-JSON token stream (the quality review's must-fix: without it
        // the warmed KV diverges from the turn at the tools block and the
        // warm buys nothing).
        let inputs = MLXToolMapping.prefixInputs(for: tools)
        #expect(inputs.toolNames == ["get_document", "web_search"])
    }

    @Test("every permutation of the same tools yields the identical derivation — warm ≡ live turn")
    func permutationsAreEquivalent() throws {
        let forward = MLXToolMapping.prefixInputs(for: tools)
        let backward = MLXToolMapping.prefixInputs(for: tools.reversed())
        #expect(forward.toolNames == backward.toolNames)
        let forwardSpecs = try #require(forward.specs)
        let backwardSpecs = try #require(backward.specs)
        #expect(forwardSpecs.count == backwardSpecs.count)
        for (lhs, rhs) in zip(forwardSpecs, backwardSpecs) {
            let lhsFunction = try #require(lhs["function"] as? [String: any Sendable])
            let rhsFunction = try #require(rhs["function"] as? [String: any Sendable])
            #expect(lhsFunction["name"] as? String == rhsFunction["name"] as? String)
        }
    }

    @Test("an empty tool list yields nil specs (the bare-persona key), not an empty array")
    func emptyToolsAreNilSpecs() {
        let inputs = MLXToolMapping.prefixInputs(for: [])
        #expect(inputs.specs == nil)
        #expect(inputs.toolNames.isEmpty)
    }

    @Test("specs are exactly toolSpec(from:) per tool, in canonical order")
    func specsMatchTheLiveMapper() throws {
        let inputs = MLXToolMapping.prefixInputs(for: tools)
        let specs = try #require(inputs.specs)
        let canonical = tools.sorted { $0.name < $1.name }
        #expect(specs.count == 2)
        for (spec, tool) in zip(specs, canonical) {
            let function = try #require(spec["function"] as? [String: any Sendable])
            #expect(function["name"] as? String == tool.name)
        }
        // The offset optionality must survive — the warmed prefix renders the
        // SAME schema the turn renders, or the keys differ byte-wise.
        // (get_document sorts first.)
        let function = try #require(specs[0]["function"] as? [String: any Sendable])
        let parameters = try #require(function["parameters"] as? [String: any Sendable])
        #expect((parameters["required"] as? [String]) == ["title"])
    }
}

struct MLXToolSpecTests {
    @Test("a ToolDefinition becomes a function-typed JSON schema")
    func toolSpecShape() {
        let definition = ToolDefinition(
            name: "web_search",
            description: "Search the web.",
            parameters: [ToolParameterDefinition(name: "query", description: "the query")]
        )
        let spec = MLXToolMapping.toolSpec(from: definition)

        #expect(spec["type"] as? String == "function")
        let function = try? #require(spec["function"] as? [String: any Sendable])
        #expect(function?["name"] as? String == "web_search")
        #expect(function?["description"] as? String == "Search the web.")

        let parameters = function?["parameters"] as? [String: any Sendable]
        #expect(parameters?["type"] as? String == "object")
        #expect((parameters?["required"] as? [String]) == ["query"])
        let properties = parameters?["properties"] as? [String: any Sendable]
        let queryProp = properties?["query"] as? [String: any Sendable]
        #expect(queryProp?["type"] as? String == "string")
        #expect(queryProp?["description"] as? String == "the query")
    }
}

struct MLXChatMessageTests {
    @Test("a user message maps to the user role")
    func userRole() {
        let message = MLXToolMapping.chatMessage(from: .user("hello"))
        #expect(message.role == .user)
        #expect(message.content == "hello")
    }

    @Test("a system message maps to the system role (the persona's seat)")
    func systemRole() {
        let message = MLXToolMapping.chatMessage(from: .system("You are M1K3."))
        #expect(message.role == .system)
        #expect(message.content == "You are M1K3.")
    }

    @Test("a tool result maps to the tool role")
    func toolRole() {
        let message = MLXToolMapping.chatMessage(from: .toolResult(name: "search", output: "found it"))
        #expect(message.role == .tool)
        #expect(message.content == "found it")
    }

    @Test("an assistant tool call echoes back as Gemma call-text")
    func assistantCallEcho() {
        let call = ParsedToolCall(name: "search", arguments: ["query": .string("seals")])
        let message = MLXToolMapping.chatMessage(from: .assistant(text: nil, toolCalls: [call]))
        #expect(message.role == .assistant)
        #expect(message.content.contains("call:search"))
        #expect(message.content.contains("<escape>seals<escape>"))
    }

    @Test("an assistant plain-text turn keeps its text")
    func assistantText() {
        let message = MLXToolMapping.chatMessage(from: .assistant(text: "done", toolCalls: []))
        #expect(message.role == .assistant)
        #expect(message.content == "done")
    }
}

struct MLXGemmaCallTextTests {
    @Test("string args are escape-wrapped; numeric args are raw")
    func callTextEncoding() {
        let call = ParsedToolCall(name: "lookup", arguments: ["q": .string("x y"), "n": .int(3)])
        let text = MLXToolMapping.gemmaCallText(call)
        #expect(text.contains("call:lookup"))
        #expect(text.contains("q:<escape>x y<escape>"))
        #expect(text.contains("n:3"))
    }

    @Test("the json dialect renders a <tool_call> block (Qwen/Llama)")
    func jsonCallText() {
        let call = ParsedToolCall(name: "search", arguments: ["query": .string("seals")])
        let text = MLXToolMapping.callText(call, format: .json)
        #expect(text.contains("<tool_call>"))
        #expect(text.contains("</tool_call>"))
        #expect(text.contains("\"name\":\"search\""))
        // Plain JSON scalar, NOT the synthesized enum container
        // {"string":{"_0":"seals"}} — a .json-dialect model reads this echo.
        #expect(text.contains("\"arguments\":{\"query\":\"seals\"}"))
    }

    @Test("json call text is valid RFC-8259 JSON for mixed argument types")
    func jsonCallTextIsRealJSON() throws {
        let call = ParsedToolCall(name: "lookup", arguments: [
            "query": .string("seals"),
            "limit": .int(3),
            "strict": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "filters": .object(["depth": .double(1.5), "none": .null]),
        ])
        let text = MLXToolMapping.callText(call, format: .json)
        let payload = text
            .replacingOccurrences(of: "<tool_call>", with: "")
            .replacingOccurrences(of: "</tool_call>", with: "")
        let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        let parsed = try #require(object)
        #expect(parsed["name"] as? String == "lookup")
        let arguments = try #require(parsed["arguments"] as? [String: Any])
        #expect(arguments["query"] as? String == "seals")
        #expect(arguments["limit"] as? Int == 3)
        #expect(arguments["strict"] as? Bool == true)
        #expect(arguments["tags"] as? [String] == ["a", "b"])
        let filters = try #require(arguments["filters"] as? [String: Any])
        #expect(filters["depth"] as? Double == 1.5)
        #expect(filters["none"] is NSNull)
    }

    @Test("the xmlFunction dialect renders <function=>/<parameter=> (Qwen3.5)")
    func xmlFunctionCallText() {
        let call = ParsedToolCall(name: "search", arguments: ["query": .string("seals"), "limit": .int(3)])
        let text = MLXToolMapping.callText(call, format: .xmlFunction)
        #expect(text.hasPrefix("<function=search>"))
        #expect(text.hasSuffix("</function>"))
        #expect(text.contains("<parameter=query>seals</parameter>"))
        #expect(text.contains("<parameter=limit>3</parameter>"))
    }

    @Test("the gemma4 dialect renders <|tool_call> with the <|\"|> escape (Gemma 4)")
    func gemma4CallText() {
        let call = ParsedToolCall(name: "lookup", arguments: ["q": .string("x y"), "n": .int(3)])
        let text = MLXToolMapping.callText(call, format: .gemma4)
        #expect(text.hasPrefix("<|tool_call>call:lookup{"))
        #expect(text.hasSuffix("}<tool_call|>"))
        // String args wrapped in Gemma 4's new <|"|> escape marker; scalars raw.
        #expect(text.contains("q:<|\"|>x y<|\"|>"))
        #expect(text.contains("n:3"))
        // Regression guard: must NOT leak the Gemma 3 dialect (the pre-flip
        // default arm rendered JSON; a copy-paste could render <start_function_call>).
        #expect(!text.contains("<start_function_call>"))
        #expect(!text.contains("<escape>"))
    }
}

struct MLXToolFormatResolutionTests {
    @Test("resolves the native dialect by model family")
    func familyResolution() {
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "mlx-community/gemma-3-1b")) == .gemma)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "mlx-community/Qwen3-1.7B")) == .json)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "meta/Llama-3.2-1B")) == .json)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "some/unknown-model")) == nil)
    }

    @Test("gemma-4 resolves to .gemma4 (native parser on main) BEFORE the generic gemma arm")
    func gemma4ResolvesGemma4() {
        let gemma4 = ModelConfiguration(id: "mlx-community/gemma-4-e4b-it-4bit")
        let gemma3n = ModelConfiguration(id: "mlx-community/gemma-3n-E4B-it-lm-4bit")
        let gemma3 = ModelConfiguration(id: "mlx-community/gemma3-1b-it-4bit")
        // gemma-4 routes native now that we build off main (#183 GemmaFunctionParser).
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: gemma4) == .gemma4)
        // gemma3n / gemma3 contain "gemma" but NOT "gemma4" → still the generic .gemma arm.
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: gemma3n) == .gemma)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: gemma3) == .gemma)
    }

    @Test("qwen3.5 resolves to xmlFunction BEFORE the generic qwen arm")
    func qwen35ResolvesXMLFunction() {
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "mlx-community/Qwen3.5-2B-4bit")) == .xmlFunction)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "mlx-community/Qwen3.5-9B-4bit")) == .xmlFunction)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "mlx-community/Qwen3-1.7B-4bit")) == .json)
        // The WIRED dense tier (lil) resolves to .json — the agentic path
        // depends on this; Qwen3 (no ".5") must NOT hit the xmlFunction arm.
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "mlx-community/Qwen3-4B-4bit")) == .json)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "mlx-community/Qwen3-8B-4bit")) == .json)
    }

    @Test("ternary Bonsai resolves per size: 8B (Qwen3 QAT) → .json, 27B (qwen3_5) → .xmlFunction")
    func bonsaiResolvesJSON() {
        // prism-ml's Ternary-Bonsai ids carry no "qwen" substring, but the 8B is
        // Qwen3-8B ternary QAT (config.json: model_type "qwen3", Qwen3ForCausalLM;
        // chat template emits <tool_call> JSON — verified 2026-07-15). Without a
        // family match it would silently fall to the ReAct floor.
        #expect(MLXGemmaProvider.resolveToolCallFormat(
            for: .init(id: "prism-ml/Ternary-Bonsai-8B-mlx-2bit")
        ) == .json)
        // The 27B is a DIFFERENT family than the 8B: config model_type "qwen3_5"
        // (Qwen3_5ForConditionalGeneration) and its chat template renders the
        // Qwen3.5 XML function dialect (<tool_call>\n<function=name>\n
        // <parameter=…>) — verified against the HF config + chat_template.jinja
        // 2026-07-17, which is the re-verification the old nil pin demanded.
        // It must ride the .xmlFunction arm, NOT the 8B's .json arm.
        #expect(MLXGemmaProvider.resolveToolCallFormat(
            for: .init(id: "prism-ml/Ternary-Bonsai-27B-mlx-2bit")
        ) == .xmlFunction)
    }

    @Test("config.json model_type decides the dialect before the name heuristic")
    func modelTypeWins() {
        // Qwen3.8-27B is model_type qwen3_5 (verified against the HF config
        // 2026-09-05) and its template emits <function=…>. The name contains
        // "qwen" but not "qwen3.5", so the name arm alone routed it to .json —
        // silently degrading tool-use to 0/5, the exact 08-08 regression shape.
        let qwen38 = ModelConfiguration(id: "mlx-community/Qwen3.8-27B-4bit")
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: qwen38, modelType: "qwen3_5") == .xmlFunction)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: qwen38, modelType: "qwen3_5_text") == .xmlFunction)
        // A dense Qwen3 under a brand id with no "qwen" substring — the type
        // carries what the name cannot.
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "acme/brand-8B"), modelType: "qwen3") == .json)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "acme/brand"), modelType: "gemma4_unified") == .gemma4)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "acme/brand"), modelType: "gemma3_text") == .gemma)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "acme/brand"), modelType: "lfm2") == .lfm2)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "acme/brand"), modelType: "glm4") == .glm4)
        // An unknown type falls through to the name heuristic, never to nil.
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "x/Qwen3-4B"), modelType: "novel_arch") == .json)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "some/unknown"), modelType: "novel_arch") == nil)
    }

    @Test("Qwen3.8 resolves to xmlFunction by name too (pre-download, before config.json exists)")
    func qwen38NameArm() {
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "mlx-community/Qwen3.8-27B-4bit")) == .xmlFunction)
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: .init(id: "lmstudio-community/Qwen3.8-27B-MLX-6bit")) == .xmlFunction)
    }

    @Test("an explicit configuration format wins over the family heuristic")
    func explicitWins() {
        var config = ModelConfiguration(id: "some/unknown-model")
        config.toolCallFormat = .json
        #expect(MLXGemmaProvider.resolveToolCallFormat(for: config) == .json)
    }

    @Test("supportsToolCalls reflects whether the family is recognised")
    func capabilityFlag() {
        #expect(MLXGemmaProvider(modelID: "mlx-community/gemma-3-1b-it-qat-4bit").supportsToolCalls)
        #expect(MLXGemmaProvider(modelID: "mlx-community/Qwen3-1.7B-4bit").supportsToolCalls)
        #expect(!MLXGemmaProvider(modelID: "some/unknown-model").supportsToolCalls)
    }
}

struct MLXThinkTemplateTests {
    @Test("qwen3.5 templates pre-open <think> — the output needs a synthetic opener")
    func qwen35PreOpensThink() {
        #expect(MLXGemmaProvider.templatePreOpensThink(for: .init(id: "mlx-community/Qwen3.5-2B-4bit")))
        #expect(MLXGemmaProvider.templatePreOpensThink(for: .init(id: "mlx-community/Qwen3.5-9B-4bit")))
        #expect(MLXGemmaProvider.templatePreOpensThink(for: .init(id: "mlx-community/qwen3_5-instruct")))
        // Bonsai-27B is qwen3_5 under a brand id with NO qwen spelling — its
        // template ends the generation prompt with an opened <think> (verified
        // against the HF chat_template.jinja 2026-07-17). Without this arm the
        // name heuristic misses it and reasoning splitting never engages.
        #expect(MLXGemmaProvider.templatePreOpensThink(
            for: .init(id: "prism-ml/Ternary-Bonsai-27B-mlx-2bit")
        ))
    }

    @Test("qwen3 and non-reasoning families do NOT pre-open think")
    func othersDoNot() {
        #expect(!MLXGemmaProvider.templatePreOpensThink(for: .init(id: "mlx-community/Qwen3-1.7B-4bit")))
        // The WIRED dense tier (lil): verified against the real Qwen3 chat
        // template — it pre-opens <think> ONLY when thinking is disabled, so the
        // default reasoning path must NOT add a synthetic opener.
        #expect(!MLXGemmaProvider.templatePreOpensThink(for: .init(id: "mlx-community/Qwen3-4B-4bit")))
        #expect(!MLXGemmaProvider.templatePreOpensThink(for: .init(id: "mlx-community/Qwen3-8B-4bit")))
        #expect(!MLXGemmaProvider.templatePreOpensThink(for: .init(id: "mlx-community/gemma-4-e4b-it-4bit")))
        #expect(!MLXGemmaProvider.templatePreOpensThink(for: .init(id: "meta/Llama-3.2-1B")))
        // The Bonsai-27B arm must not over-reach to the 8B — that one is dense
        // Qwen3 (no pre-open).
        #expect(!MLXGemmaProvider.templatePreOpensThink(
            for: .init(id: "prism-ml/Ternary-Bonsai-8B-mlx-2bit")
        ))
    }

    @Test("enable_thinking toggle support spans the WHOLE Qwen3 family, not just 3.5")
    func thinkingToggleFamilies() {
        // The bug this guards: the dense-Qwen3 swap (#94) moved lil/huge to plain
        // Qwen3, but toggle support was (wrongly) tied to the 3.5-only pre-open
        // check — so fast mode could never send enable_thinking:false and the model
        // thought on every turn. ALL Qwen3 honour the switch (verified: the template
        // pre-opens <think> only when thinking is disabled = it reads the flag).
        #expect(MLXGemmaProvider.templateSupportsThinkingToggle(for: .init(id: "mlx-community/Qwen3-4B-4bit")))
        #expect(MLXGemmaProvider.templateSupportsThinkingToggle(for: .init(id: "mlx-community/Qwen3-8B-4bit")))
        #expect(MLXGemmaProvider.templateSupportsThinkingToggle(for: .init(id: "mlx-community/Qwen3-1.7B-4bit")))
        #expect(MLXGemmaProvider.templateSupportsThinkingToggle(for: .init(id: "mlx-community/Qwen3.5-9B-4bit")))
        #expect(MLXGemmaProvider.templateSupportsThinkingToggle(for: .init(id: "mlx-community/qwen3_5-instruct")))
        // Families with no enable_thinking switch.
        #expect(!MLXGemmaProvider.templateSupportsThinkingToggle(for: .init(id: "mlx-community/gemma-4-e4b-it-4bit")))
        #expect(!MLXGemmaProvider.templateSupportsThinkingToggle(for: .init(id: "meta/Llama-3.2-1B")))
    }

    @Test("the synthetic opener is added once and never duplicated")
    func normalisePrefix() {
        #expect(MLXGemmaProvider.normaliseThinkPrefix("plan</think>answer", preOpened: true)
            == "<think>plan</think>answer")
        #expect(MLXGemmaProvider.normaliseThinkPrefix("<think>plan</think>answer", preOpened: true)
            == "<think>plan</think>answer")
        #expect(MLXGemmaProvider.normaliseThinkPrefix("plain answer", preOpened: false)
            == "plain answer")
    }
}

struct MLXParsedToolCallTests {
    @Test("a library ToolCall maps to our ParsedToolCall with typed args")
    func parsedToolCallMapping() {
        let libraryCall = MLXLMCommon.ToolCall(
            function: .init(name: "search", arguments: ["query": "seal", "limit": 5, "fuzzy": true])
        )
        let parsed = MLXToolMapping.parsedToolCall(from: libraryCall)

        #expect(parsed.name == "search")
        #expect(parsed.arguments["query"] == .string("seal"))
        #expect(parsed.arguments["limit"] == .int(5))
        #expect(parsed.arguments["fuzzy"] == .bool(true))
    }

    @Test("nested JSON values round-trip through the conversion")
    func nestedJSONValue() {
        let libraryCall = MLXLMCommon.ToolCall(
            function: .init(name: "f", arguments: ["tags": ["a", "b"]])
        )
        let parsed = MLXToolMapping.parsedToolCall(from: libraryCall)
        #expect(parsed.arguments["tags"] == .array([.string("a"), .string("b")]))
    }

    @Test("images ride the user chat message ONLY when the session allows them")
    func imagesGatedByCapability() {
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        let message = ToolMessage.user("what is this?", images: [ImageAttachment(url: url)])

        // Vision-capable session (VLM-loaded 12B): image URL flows through.
        let allowed = MLXToolMapping.chatMessage(from: message, imagesAllowed: true)
        #expect(allowed.role == .user)
        #expect(allowed.content == "what is this?")
        #expect(allowed.images.count == 1)
        if case let .url(passed) = allowed.images.first {
            #expect(passed == url)
        } else {
            Issue.record("expected a .url image part")
        }

        // Text-only model (default): images dropped, text identical — a
        // pre-vision render is byte-for-byte what it was.
        let dropped = MLXToolMapping.chatMessage(from: message)
        #expect(dropped.images.isEmpty)
        #expect(dropped.content == "what is this?")

        // Bare text user turn is unchanged either way.
        #expect(MLXToolMapping.chatMessage(from: .user("hi"), imagesAllowed: true).images.isEmpty)
    }
}

/// swift-jinja's `tojson` sorts keys, so the template renders a tool as
/// `{"function":{"description":…,"name":…},"type":"function"}` — LFM2.5-1.2B
/// made 0/5 tool calls on that rendering and 5/5 on the OpenAI order it was
/// trained on (mlx-lm replay of the app's exact prompt, 2026-09-05). For the
/// lfm2 dialect we render the block ourselves into the system turn and hand
/// the template no tools, so `tojson` never runs.
struct LFM2ToolBlockTests {
    private let search: ToolSpec = MLXToolMapping.toolSpec(from: ToolDefinition(
        name: "search_knowledge", description: "Search the user's notes.",
        parameters: [ToolParameterDefinition(name: "query", description: "what to look up")]
    ))
    private let clock: ToolSpec = MLXToolMapping.toolSpec(from: ToolDefinition(
        name: "datetime", description: "Current date and time.", parameters: []
    ))

    @Test("canonical JSON keeps the trained key order: type, function{name, description, parameters}")
    func canonicalOrder() {
        let json = MLXToolMapping.canonicalToolJSON(search)
        #expect(json == """
        {"type": "function", "function": {"name": "search_knowledge", "description": "Search the user's notes.", \
        "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "what to look up"}}, \
        "required": ["query"]}}}
        """)
    }

    @Test("a parameterless tool renders an empty properties object and no required list")
    func parameterless() {
        let json = MLXToolMapping.canonicalToolJSON(clock)
        #expect(json == """
        {"type": "function", "function": {"name": "datetime", "description": "Current date and time.", \
        "parameters": {"type": "object", "properties": {}}}}
        """)
    }

    @Test("the block matches the Liquid template's own joins: newline, 'List of tools: [', ', ' between, ']'")
    func blockShape() {
        let block = MLXToolMapping.lfm2ToolsBlock([clock, search])
        #expect(block.hasPrefix("\nList of tools: [{\"type\": \"function\", \"function\": {\"name\": \"datetime\""))
        #expect(block.contains("}}}, {\"type\": \"function\", \"function\": {\"name\": \"search_knowledge\""))
        #expect(block.hasSuffix("]"))
    }

    @Test("lfm2: the block lands on the system turn and the template gets no tools")
    func lfm2Rewrite() {
        let chat = [Chat.Message(role: .system, content: "PERSONA"), Chat.Message(role: .user, content: "hi")]
        let out = MLXToolMapping.templateInputs(chat: chat, specs: [clock], format: .lfm2)
        #expect(out.specs == nil)
        #expect(out.chat[0].content == "PERSONA" + MLXToolMapping.lfm2ToolsBlock([clock]))
        #expect(out.chat[1].content == "hi")
    }

    @Test("other dialects pass through untouched — their templates own the rendering")
    func othersUntouched() {
        let chat = [Chat.Message(role: .system, content: "PERSONA")]
        for format in [ToolCallFormat.json, .xmlFunction, .gemma] {
            let out = MLXToolMapping.templateInputs(chat: chat, specs: [clock], format: format)
            #expect(out.specs?.count == 1)
            #expect(out.chat[0].content == "PERSONA")
        }
    }

    @Test("lfm2 with no tools changes nothing")
    func lfm2NoTools() {
        let chat = [Chat.Message(role: .system, content: "PERSONA")]
        let out = MLXToolMapping.templateInputs(chat: chat, specs: nil, format: .lfm2)
        #expect(out.specs == nil)
        #expect(out.chat[0].content == "PERSONA")
    }
}
