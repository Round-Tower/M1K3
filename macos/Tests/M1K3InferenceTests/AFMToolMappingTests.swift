//
//  AFMToolMappingTests.swift
//  M1K3InferenceTests
//
//  Phase 15 — the AFM-native tool-calling spike. Apple Foundation Models can't
//  emit a model-specific tool-call dialect the way Gemma/Qwen do, but it CAN be
//  forced to emit a structured `@Generable` decision. The provider extracts the
//  plain fields off that decision and hands them here; this pure mapper turns
//  them into the dialect-free `ToolTurn` the agent already understands. Keeping
//  the map pure (no FoundationModels) is the cheap de-risking the spike is for:
//  the one unknown is whether AFM *emits* a parseable decision live — the
//  translation of a well-formed decision is provably correct off-device.
//
//  Design note: the mapper is deliberately FAITHFUL, not defensive — a named
//  tool always becomes a `.toolCalls`, even if the name is unknown. `LocalAgent`
//  already owns unknown-tool steering + the repeat-guard; duplicating that here
//  would fork the one tested source of truth. The provider's do/catch around
//  `respond(generating:)` is the non-melt backstop, not this map.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-15, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-09 — `visionFailureReply(for:imageCount:…)`: the image-turn
//  fallback per AFMFailure class (decline / resend / fresh chat), the brain names derived per platform
//  (PR #526 second-pass review). Confidence 0.85.
//  Review: Kev + claude-fable-5.1, 2026-10-09 (2) — `visionTurn(from:imagesAttachable:)` + `visionRoute`: the
//  neutral shape exists only where `Attachment(imageURL:)` runs; elsewhere the turn is the honest
//  `.cannotShow` reply, never a persona-free session. `visionDecline(from:)` deleted (PR #526 third-pass
//  review). Confidence 0.85.

import Foundation
@testable import M1K3Inference
import Testing

struct AFMToolMappingTests {
    @Test("a final decision becomes a text turn carrying the answer")
    func finalIsText() {
        let turn = AFMToolMapping.toolTurn(
            isFinal: true, toolName: "", toolInput: "", finalAnswer: "The Sweet Track dates to 3807 BC."
        )
        #expect(turn == .text("The Sweet Track dates to 3807 BC."))
    }

    @Test("a named tool becomes a single tool call with the input under `query`")
    func namedToolIsCall() {
        let turn = AFMToolMapping.toolTurn(
            isFinal: false, toolName: "web_search", toolInput: "tide times Cork today", finalAnswer: ""
        )
        #expect(turn == .toolCalls([
            ParsedToolCall(name: "web_search", arguments: ["query": .string("tide times Cork today")]),
        ]))
    }

    @Test("an empty tool name falls through to text even when isFinal is false")
    func emptyToolNameIsText() {
        // A confused model that set neither a final flag nor a tool: prefer a
        // (possibly empty) text conclusion over fabricating a call. LocalAgent
        // concludes; the latency band proves it didn't melt.
        let turn = AFMToolMapping.toolTurn(
            isFinal: false, toolName: "   ", toolInput: "ignored", finalAnswer: "best effort"
        )
        #expect(turn == .text("best effort"))
    }

    @Test("isFinal wins even if the model also named a tool")
    func finalBeatsTool() {
        let turn = AFMToolMapping.toolTurn(
            isFinal: true, toolName: "web_search", toolInput: "x", finalAnswer: "done"
        )
        #expect(turn == .text("done"))
    }

    @Test("whitespace is trimmed off the tool name, input, and final answer")
    func trimsFields() {
        let call = AFMToolMapping.toolTurn(
            isFinal: false, toolName: "  lookup_fact ", toolInput: "  Brian Boru  ", finalAnswer: ""
        )
        #expect(call == .toolCalls([
            ParsedToolCall(name: "lookup_fact", arguments: ["query": .string("Brian Boru")]),
        ]))

        let text = AFMToolMapping.toolTurn(
            isFinal: true, toolName: "", toolInput: "", finalAnswer: "  spaced answer  "
        )
        #expect(text == .text("spaced answer"))
    }

    @Test("an unknown tool name is still emitted as a call — LocalAgent steers it")
    func unknownToolPassesThrough() {
        // The mapper does NOT validate against a tool catalogue: dispatchCall in
        // LocalAgent returns the available-tools error and steers a retry. Snapping
        // unknown→text here would silently drop the model's intent.
        let turn = AFMToolMapping.toolTurn(
            isFinal: false, toolName: "teleport", toolInput: "Mars", finalAnswer: ""
        )
        #expect(turn == .toolCalls([
            ParsedToolCall(name: "teleport", arguments: ["query": .string("Mars")]),
        ]))
    }
}

/// The image turn on Mini (2026-10-09 live probe, AFMVisionLiveTests): the persona trips the guardrail
/// and any tool palette makes Mini call a tool instead of looking, so an image turn runs the NEUTRAL,
/// tool-free shape; the honest decline is the fallback when that turn still fails.
struct AFMVisionTurnTests {
    private let image = ImageAttachment(url: URL(fileURLWithPath: "/tmp/receipt.png"))

    @Test("a latest user turn with images takes the neutral shape: no persona, no M1K3, a steer")
    func imageTurnIsNeutral() throws {
        let turn = try #require(AFMToolPrompt.visionTurn(from: [
            .system(M1K3Persona.systemPrompt(variant: nil)), .user("total?", images: [image]),
        ], imagesAttachable: true))
        #expect(!turn.instructions.contains(M1K3Persona.standingPersonaAnchor))
        #expect(!turn.instructions.contains("M1K3"))
        #expect(turn.instructions.contains("image"))
        #expect(turn.instructions.count < 160, "neutral instructions stay a sentence or two")
        // The body: the conversation, then the steer — and no tool paragraph (with one, a
        // tool-free Mini still answered "Call the calculator tool with the amount €23.40").
        #expect(turn.body.contains("Conversation:\nUser: total?"))
        #expect(turn.body.hasSuffix(AFMToolPrompt.visionSteer))
        #expect(!turn.body.contains("Decide the single next step"))
        #expect(!turn.body.contains("tool"))
    }

    @Test("the image turn's conversation is render's own: earlier turns and tool results ride along")
    func bodyKeepsTheConversation() throws {
        let messages: [ToolMessage] = [
            .user("what's here?", images: []), .assistant(text: "Notes.", toolCalls: []),
            .toolResult(name: "recall", output: "a café"), .user("and the total?", images: [image]),
        ]
        let turn = try #require(AFMToolPrompt.visionTurn(from: messages, imagesAttachable: true))
        let rendered = AFMToolPrompt.render(messages: messages, tools: [])
        #expect(rendered.hasPrefix(turn.body.replacingOccurrences(of: "\n\n" + AFMToolPrompt.visionSteer, with: "")))
        #expect(turn.body.contains("Result from recall: a café"))
    }

    @Test("no images means no neutral shape — the persona and the tools stay")
    func noImagesKeepsThePersona() {
        let text: [ToolMessage] = [.system("persona"), .user("hi", images: [])]
        #expect(AFMToolPrompt.visionTurn(from: text, imagesAttachable: true) == nil)
        #expect(AFMToolPrompt.visionTurn(from: [.system("persona")], imagesAttachable: true) == nil)
        #expect(AFMToolPrompt.visionRoute(from: text, imagesAttachable: true, platform: .mac) == nil)
        #expect(AFMToolPrompt.visionRoute(from: text, imagesAttachable: false, platform: .mac) == nil)
    }

    @Test("only the LATEST user turn counts: an old image does not strip a later text turn's persona")
    func onlyLatestTurn() {
        let messages: [ToolMessage] = [
            .user("look", images: [image]), .assistant(text: "ok", toolCalls: []), .user("thanks", images: []),
        ]
        #expect(AFMToolPrompt.visionTurn(from: messages, imagesAttachable: true) == nil)
        #expect(AFMToolPrompt.visionRoute(from: messages, imagesAttachable: false, platform: .mac) == nil)
    }

    // MARK: - Where the runtime can't attach the image (PR #526 third-pass review, finding 1)

    /// `Attachment(imageURL:)` runs only on macOS/iOS 27 under a 6.4 compiler. Before this pin the
    /// neutral shape was chosen on every image turn: on an older runtime no image was sent, the body
    /// said "(… this brain cannot view.)" and the steer said "describe it" — persona-free, tool-free,
    /// and an open invitation to confabulate. Not attachable means NO vision shape at all.
    @Test("not attachable: no neutral shape — the turn is the honest cannot-show reply")
    func notAttachableIsTheHonestReply() throws {
        let messages: [ToolMessage] = [.system("persona"), .user("total?", images: [image, image])]
        #expect(AFMToolPrompt.visionTurn(from: messages, imagesAttachable: false) == nil)
        let route = try #require(AFMToolPrompt.visionRoute(from: messages, imagesAttachable: false, platform: .mac))
        guard case let .cannotShow(reply) = route else {
            Issue.record("expected .cannotShow, got \(route)")
            return
        }
        #expect(reply.contains("won't guess"))
        #expect(reply.contains("2 images"))
        #expect(reply.contains("Lil or Big"))
        #expect(!reply.contains("describe"))
        // Nothing about the runtime is a tool or a persona: the reply is final text.
        #expect(reply.hasSuffix("."))
    }

    @Test("attachable: the route is the neutral shape, the same one visionTurn builds")
    func attachableIsTheNeutralShape() throws {
        let messages: [ToolMessage] = [.system("persona"), .user("total?", images: [image])]
        let route = try #require(AFMToolPrompt.visionRoute(from: messages, imagesAttachable: true, platform: .mac))
        #expect(try route == .see(#require(AFMToolPrompt.visionTurn(from: messages, imagesAttachable: true))))
    }

    @Test("the cannot-show reply names the brains that read images on this platform, or says none do")
    func cannotShowNamesTheReaders() {
        func reply(_ platform: BrainTier.DevicePlatform) -> String {
            AFMToolPrompt.cannotShowImageReply(imageCount: 1, readers: BrainTier.imageReaders(platform: platform))
        }
        let mac = reply(.mac), mobile = reply(.mobile)
        let none = AFMToolPrompt.cannotShowImageReply(imageCount: 1, readers: [])
        #expect(mac.contains("Lil or Big") && mac.contains("image you"))
        #expect(mobile.contains("Switch to Lil,") && !mobile.contains("Big"))
        #expect(none.contains("No brain on this device"))
        // The same closing line the guardrail decline uses: one source of the brain names.
        let guardrail = AFMToolPrompt.visionFailureReply(for: .guardrailViolation, imageCount: 1, platform: .mac)
        #expect(mac.hasSuffix(guardrail.components(separatedBy: ". ").last ?? "?"))
    }

    // MARK: - The failure reply, per class (PR #526 second-pass review, finding 1)

    /// One decline for every failure fit only the guardrail. A rate-limit, a daemon blip or a
    /// timeout is answered by a resend, and a context overflow by a fresh chat — not by a brain
    /// switch. Keyed on `AFMFailure.classify(error:)`, which both image paths already compute.
    @Test("guardrail and unknown: the honest decline, naming the brains that can read images here")
    func guardrailAndUnknownDecline() {
        for failure in [AFMFailure.guardrailViolation, .unknown] {
            let text = AFMToolPrompt.visionFailureReply(for: failure, imageCount: 1, platform: .mac)
            #expect(text.contains("couldn't read the image"))
            #expect(text.contains("won't guess"))
            #expect(text.contains("Switch to Lil or Big, which can read images"))
            #expect(!text.contains("try again"))
        }
    }

    @Test("the named brains are derived per platform: a phone is sent to Lil alone")
    func declineNamesThePlatformsReaders() {
        let text = AFMToolPrompt.visionFailureReply(for: .guardrailViolation, imageCount: 2, platform: .mobile)
        #expect(text.contains("2 images"))
        #expect(text.contains("Switch to Lil, which can read images"))
        #expect(!text.contains("Big"))
    }

    @Test("with no MLX reader on the platform the decline says so and names no brain")
    func declineWithoutAReader() {
        let text = AFMToolPrompt.visionFailureReply(for: .guardrailViolation, imageCount: 1, readers: [])
        #expect(text.contains("won't guess"))
        #expect(text.contains("No brain on this device can read images yet"))
        #expect(!text.contains("Switch to"))
        #expect(!text.contains("Lil"), "an empty reader list names nobody")
    }

    @Test("transient classes ask for a resend — no brain-switch advice")
    func transientAsksForARetry() {
        for failure in [AFMFailure.rateLimited, .daemonUnavailable, .timeout] {
            let text = AFMToolPrompt.visionFailureReply(for: failure, imageCount: 1, platform: .mac)
            #expect(text.contains("try again in a moment"), "\(failure)")
            #expect(!text.contains("Switch to"), "\(failure)")
            #expect(!text.contains("won't guess"), "\(failure)")
        }
    }

    @Test("a context overflow sends the user to a fresh chat, not another brain")
    func overflowAsksForAFreshChat() {
        let text = AFMToolPrompt.visionFailureReply(for: .contextOverflow, imageCount: 1, platform: .mac)
        #expect(text.contains("too long to read an image alongside"))
        #expect(text.contains("start a fresh chat"))
        #expect(!text.contains("Switch to"))
        #expect(!text.contains("try again in a moment"))
    }

    @Test("every failure class has a reply, each ends a sentence, and the count rides the noun")
    func everyClassReplies() {
        for failure in AFMFailure.allCases {
            let one = AFMToolPrompt.visionFailureReply(for: failure, imageCount: 1, platform: .mac)
            let three = AFMToolPrompt.visionFailureReply(for: failure, imageCount: 3, platform: .mac)
            #expect(!one.isEmpty && one.hasSuffix("."), "\(failure)")
            #expect(!one.contains("3 images") && !three.contains(" image you"), "\(failure)")
        }
    }

    @Test("imagesAttachable is the one availability read both AFM image paths share")
    func imagesAttachableMatchesTheRuntime() {
        var expected = false
        #if compiler(>=6.4)
            if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) { expected = true }
        #endif
        #expect(AFMToolPrompt.imagesAttachable == expected)
    }
}
