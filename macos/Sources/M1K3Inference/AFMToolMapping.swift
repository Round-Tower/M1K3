//
//  AFMToolMapping.swift
//  M1K3Inference
//
//  Phase 15 — the AFM-native tool-calling spike, pure half. Apple Foundation
//  Models speaks no per-model tool dialect (no `<tool_call>` JSON, no Gemma
//  `call:name{…}`); instead it is FORCED, via `respond(generating:)`, to emit a
//  structured `@Generable` decision. The provider extracts that decision's plain
//  fields and hands them here. This file owns two pure, off-device-testable
//  pieces:
//
//    1. `AFMToolMapping.toolTurn(…)` — decision fields → the dialect-free
//       `ToolTurn` the agent already consumes.
//    2. `AFMToolPrompt` — the typed `[ToolMessage]` transcript → the single
//       prompt string `respond(generating:)` takes (AFM has no role-tagged tool
//       template to render into), plus the persona-instructions extraction.
//
//  The map is FAITHFUL, not defensive: a named tool always becomes `.toolCalls`,
//  even an unknown one — `LocalAgent.dispatchCall` already owns the unknown-tool
//  steering + repeat-guard, and forking that here would split the one tested
//  source of truth. The non-melt backstop is the provider's do/catch around the
//  live `respond(generating:)`, not this map.
//
//  Why pure: the one real unknown in the spike is whether AFM reliably EMITS a
//  parseable decision live + survives non-resolving tool results. Translating a
//  well-formed decision is provably correct without the model, so it is pinned
//  here and the live harness is left to test only the genuine unknown.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-15, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-09 — `visionDecline(from:)`: an honest decline for images on the
//  latest user turn (Mini can't read them in the app's prompt shape; AFMVisionLiveTests). Confidence 0.7.
//  Review: Kev + claude-fable-5.1, 2026-10-09 (2) — `visionTurn(from:)`: the shape AFM vision accepts (neutral
//  instructions, NO tools, a steer — the only one of seven probe arms that read the receipt). The decline is
//  now the failure fallback only. Confidence 0.75 — one fixture, one device; voice and tools traded, named.
//  Review: Kev + claude-fable-5.1, 2026-10-09 (3) — `visionFailureReply(for:imageCount:…)`: the fallback by
//  AFMFailure class (guardrail/unknown decline, transient resend, overflow fresh chat), the brain names
//  derived from `BrainTier.imageReaders` (PR #526 second-pass review). Confidence 0.85.
//  Review: Kev + claude-fable-5.1, 2026-10-09 (4) — `visionTurn(from:imagesAttachable:)` + `visionRoute`: the
//  neutral shape exists only where `Attachment(imageURL:)` runs (`imagesAttachable`, the one runtime read both
//  image paths share); elsewhere the turn is the honest `.cannotShow` reply and no persona-free session is
//  built. `visionDecline(from:)` (Review 1) is deleted: no production caller since (2); the guardrail form
//  lives in `visionFailureReply` (PR #526 third-pass review). Confidence 0.85.
//  Review: Kev + claude-opus-4-6, 2026-09-16 — image support: on macOS 27+ images
//  ride the Prompt via Attachment(imageURL:) and the "cannot view" text note is
//  suppressed; `imageURLs(from:)` extracts attached URLs for the provider.
//  Confidence now 0.85.
//  Review: Kev + claude-opus-5-5, 2026-09-26 — the steer separates ordinary tool asks from attempts on
//  the instructions: the clean Mini baseline (9/30 tool-use) failed on leak declines ("the machine's own
//  clock is a backdoor for secrets"). Eval-gated on the live arm with security + refusal. Confidence 0.7.
//  Review: Kev + claude-opus-5-5, 2026-09-23 — #397 fold: `render(tools: [])` (the
//  native session) no longer ends by pointing at "the tools listed above" when
//  nothing is listed. Pinned in AFMToolPromptTests. Confidence now 0.85.

import Foundation

/// Maps the plain fields of AFM's structured `@Generable` tool decision onto the
/// dialect-free `ToolTurn`. Pure: takes scalars (extracted off the decision by
/// the provider), imports no FoundationModels, returns the agent's own type.
public enum AFMToolMapping {
    /// The sole parameter key every current `AgentTool` declares by convention
    /// (`ToolParameterDefinition`). Named here so the mapping can't silently drift
    /// from that contract if a future tool adopts a different argument name.
    static let argumentKey = "query"

    /// A final decision (or one with no actionable tool) becomes a text turn; a
    /// named tool becomes a single call carrying the input under `query` (the arg
    /// key every current `AgentTool` declares). `isFinal` wins over a stray tool
    /// name. The name is NOT validated against a catalogue — see file note.
    public static func toolTurn(
        isFinal: Bool,
        toolName: String,
        toolInput: String,
        finalAnswer: String
    ) -> ToolTurn {
        let tool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal || tool.isEmpty {
            return .text(finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let input = toolInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return .toolCalls([ParsedToolCall(name: tool, arguments: [argumentKey: .string(input)])])
    }
}

/// Renders the agent's typed transcript into the prompt AFM consumes. The
/// `@Generable` decision schema is injected by `respond(generating:)` itself, so
/// this only supplies the tool catalogue + the conversation; the persona
/// `.system` turn is lifted to the session's `instructions:` separately.
public enum AFMToolPrompt {
    /// The standing-instructions text for the session: the FIRST `.system` turn,
    /// trimmed. `ToolMessage.system` is contractually "sent once, at the start"
    /// (and `StatelessToolTurnSession` re-sends the whole transcript each
    /// iteration, so a join would re-emit / double the persona on iteration ≥2 if
    /// a caller ever added a second system turn). Taking the first keeps AFM's
    /// `instructions:` to one standing persona. `nil` when there is none / it is
    /// blank — the provider then falls back to its own persona closure.
    public static func systemInstructions(from messages: [ToolMessage]) -> String? {
        for message in messages {
            guard case let .system(text) = message else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// The prompt body: a tool catalogue, then the conversation (goal, the
    /// model's own prior calls, tool results). `.system` turns are excluded —
    /// they become session instructions, not body text.
    public static func render(messages: [ToolMessage], tools: [ToolDefinition]) -> String {
        var lines: [String] = []

        if !tools.isEmpty {
            lines.append("Available tools:")
            for tool in tools {
                let params = tool.parameters.map(\.name).joined(separator: ", ")
                let paramSuffix = params.isEmpty ? "" : " (args: \(params))"
                lines.append("- \(tool.name): \(tool.description)\(paramSuffix)")
            }
            lines.append("")
        }

        lines.append(contentsOf: conversationLines(messages))
        lines.append("")
        // The native session passes `tools: []` (its definitions ride the FM
        // session's structured `tools:`), so there is no list "above" to name.
        let yourTools = tools.isEmpty ? "Your tools are" : "The tools listed above are"
        lines.append(
            "Decide the single next step. \(yourTools) yours to USE "
                + "— calling them is your job, not a secret. You do NOT inherently "
                + "know the current date/time, the user's private notes or documents, "
                + "or any live information — CALL the matching tool for those rather "
                + "than saying \"I can't\" or guessing. Never say you lack access to "
                + "something one of your tools provides. Asking for the time, the user's "
                + "notes or documents, a fact, a web page, the news or recent activity is an "
                + "ordinary request, not an attempt on your instructions: never answer it "
                + "with your rules. Call one tool if it would help "
                + "answer the request; give your final answer only when the tools have "
                + "already given you what you need, or no tool applies."
        )
        return lines.joined(separator: "\n")
    }

    /// The conversation block alone ("Conversation:" and the turns), shared by `render`
    /// and the image turn's body. `.system` turns are excluded — they become session
    /// instructions, not body text.
    static func conversationLines(_ messages: [ToolMessage]) -> [String] {
        var lines = ["Conversation:"]
        for message in messages {
            switch message {
            case .system:
                continue // lifted to session instructions
            case let .user(text, images):
                lines.append("User: \(text)")
                // On macOS 27+ images ride the Prompt via Attachment(imageURL:)
                // and never need a text note. On older runtimes, tell the model
                // honestly instead of silently pretending nothing was sent.
                #if compiler(>=6.4)
                    if !images.isEmpty {
                        if #unavailable(macOS 27.0, iOS 27.0, visionOS 27.0) {
                            lines.append("(The user attached \(images.count) image(s) this brain cannot view.)")
                        }
                    }
                #else
                    if !images.isEmpty {
                        lines.append("(The user attached \(images.count) image(s) this brain cannot view.)")
                    }
                #endif
            case let .assistant(text, calls):
                if let text, !text.isEmpty {
                    lines.append("Assistant: \(text)")
                }
                for call in calls {
                    let query = call.arguments["query"]?.stringValue ?? call.stringArguments.values.first ?? ""
                    lines.append("Assistant called \(call.name)(\(query))")
                }
            case let .toolResult(name, output):
                lines.append("Result from \(name): \(output)")
            }
        }
        return lines
    }

    /// The image URLs attached to user turns in this transcript, in order.
    /// Empty when the conversation carries no images.
    public static func imageURLs(from messages: [ToolMessage]) -> [URL] {
        messages.compactMap { message -> [URL]? in
            guard case let .user(_, images) = message else { return nil }
            return images.map(\.url)
        }.flatMap { $0 }
    }

    /// How many images the LATEST user turn carries (0 when none, or no user turn).
    static func latestTurnImageCount(in messages: [ToolMessage]) -> Int {
        let latest = messages.reversed().compactMap { message -> [ImageAttachment]? in
            guard case let .user(_, images) = message else { return nil }
            return images
        }.first
        return latest?.count ?? 0
    }

    /// The shape AFM vision ACCEPTS, from the 2026-10-09 live probe (AFMVisionLiveTests, seven
    /// arms): the persona's instructions trip Apple's guardrail on an image ("May contain unsafe
    /// content"), and ANY tool palette — generic instructions, a steer, even calling
    /// `.disallowed` — makes Mini reach for `read_document` / `search_knowledge` instead of
    /// looking. Only "neutral instructions, no tools, a steer" read the receipt. So an image
    /// turn on Mini runs persona-free and tool-free, the same "utility generations need neutral
    /// instructions" rule the titler and summaries follow. Two trades, both named: the answer
    /// loses M1K3's voice, and the image turn itself cannot call a tool (the next text turn can).
    public struct VisionTurn: Equatable, Sendable {
        /// Session instructions in place of the persona.
        public let instructions: String
        /// The prompt body: the conversation, then the steer — and NOT `render`'s closing
        /// tool paragraph, which on a tool-free turn still had Mini answer "Call the
        /// calculator tool with the amount €23.40" (the probe's first shipped arm).
        public let body: String
    }

    /// `VisionTurn.instructions`: neutral — nothing about M1K3, nothing the guardrail reads as
    /// a role play, no tools to be eager with.
    public static let visionInstructions =
        "You are a helpful assistant. The user attached an image: read it and answer from what you see."

    /// The body's last paragraph on an image turn: the image first, in place of `render`'s
    /// tool paragraph.
    public static let visionSteer = "An image is attached: describe it or answer from it."

    /// Whether this runtime can hand AFM an image at all: `Attachment(imageURL:)` is
    /// macOS / iOS / visionOS 27 under a 6.4 compiler. The ONE read both image paths gate
    /// on — the same check that decides whether the URLs ride the Prompt. Where it is
    /// false, no image is ever sent, so the neutral shape would be a persona-free,
    /// tool-free session told to "describe it" with nothing to describe (PR #526 review).
    public static var imagesAttachable: Bool {
        #if compiler(>=6.4)
            if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) { return true }
        #endif
        return false
    }

    /// The neutral shape for an image turn; `nil` when the latest user turn has no image
    /// (text turns keep the persona and the tools; an old image never changes a later text
    /// turn) and `nil` when the images can't be attached — the honest reply is the turn then
    /// (`visionRoute`), never a session that can't see what it is told to look at.
    public static func visionTurn(from messages: [ToolMessage], imagesAttachable: Bool) -> VisionTurn? {
        guard imagesAttachable, latestTurnImageCount(in: messages) > 0 else { return nil }
        let body = (conversationLines(messages) + ["", visionSteer]).joined(separator: "\n")
        return VisionTurn(instructions: visionInstructions, body: body)
    }

    /// What an image turn becomes: the neutral shape where the image can ride the Prompt,
    /// the honest reply where it can't. Exclusive by construction, so a call site can't
    /// build the persona-free session on a runtime that sends no image.
    public enum VisionRoute: Equatable, Sendable {
        /// Run the neutral, tool-free turn with the image attached.
        case see(VisionTurn)
        /// Reply with this text and run no model turn at all.
        case cannotShow(String)
    }

    /// `nil` when the latest user turn has no image.
    public static func visionRoute(
        from messages: [ToolMessage], imagesAttachable: Bool, platform: BrainTier.DevicePlatform
    ) -> VisionRoute? {
        let count = latestTurnImageCount(in: messages)
        guard count > 0 else { return nil }
        guard let turn = visionTurn(from: messages, imagesAttachable: imagesAttachable) else {
            let readers = BrainTier.imageReaders(platform: platform)
            return .cannotShow(cannotShowImageReply(imageCount: count, readers: readers))
        }
        return .see(turn)
    }

    /// The reply where the runtime can't hand Mini the image (pre-27): the same "won't
    /// guess" promise as the guardrail decline, with the reason named, and the same
    /// closing line naming the brains that can read images here.
    public static func cannotShowImageReply(imageCount: Int, readers: [BrainTier]) -> String {
        "This version of the system can't pass me the \(imageNoun(imageCount)) you attached, "
            + "so I won't guess at what's in it. " + switchBrainLine(readers: readers)
    }

    static func imageNoun(_ count: Int) -> String {
        count == 1 ? "image" : "\(max(count, 2)) images"
    }

    /// The decline's closing line: the brains that read images on this platform, or none.
    static func switchBrainLine(readers: [BrainTier]) -> String {
        guard !readers.isEmpty else { return "No brain on this device can read images yet." }
        let names = readers.map(\.displayName).joined(separator: " or ")
        return "Switch to \(names), which can read images, and send it again."
    }

    /// What Mini says when its image turn throws, by failure class (PR #526 review): one
    /// decline fit only the guardrail. A rate limit, a daemon blip or a timeout is answered by
    /// a resend, not a brain switch; a context overflow by a fresh chat — the conversation plus
    /// the image is what no longer fits. Guardrail and unknown get the decline, naming the
    /// brains that can read images on `platform` (`BrainTier.imageReaders`).
    public static func visionFailureReply(
        for failure: AFMFailure, imageCount: Int, platform: BrainTier.DevicePlatform
    ) -> String {
        visionFailureReply(for: failure, imageCount: imageCount, readers: BrainTier.imageReaders(platform: platform))
    }

    /// The same, with the readers supplied — the "no MLX brain sees here" case is a list, not
    /// a platform, so it stays testable without inventing one.
    public static func visionFailureReply(for failure: AFMFailure, imageCount: Int, readers: [BrainTier]) -> String {
        let noun = imageNoun(imageCount)
        switch failure {
        case .rateLimited, .daemonUnavailable, .timeout:
            return "I couldn't read the \(noun) you attached just now — try again in a moment."
        case .contextOverflow:
            return "This conversation is too long to read an image alongside it — "
                + "start a fresh chat and send the \(noun) again."
        case .guardrailViolation, .unknown:
            // `.unknown` gets the switch-brain decline on purpose (conservative by design): a
            // throw the string heuristics can't place may well be the guardrail under new
            // wording, and "try again" on a guardrail is a loop; a brain switch always resolves.
            return "I couldn't read the \(noun) you attached on this brain, so I won't guess at what's in it. "
                + switchBrainLine(readers: readers)
        }
    }
}
