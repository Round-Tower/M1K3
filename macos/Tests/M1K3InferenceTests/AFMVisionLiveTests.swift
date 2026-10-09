//
//  AFMVisionLiveTests.swift
//  M1K3InferenceTests
//
//  Live, opt-in (`M1K3_AFM_EVAL=1`): can Mini actually SEE? The 2026-10-06 vision baseline put Mini
//  at 1/16 — every answer a confident confabulation — while Big scored 14/16 on the same images.
//  The app sends images as `Attachment(imageURL:)`, a file URL handed to an out-of-process model.
//  This asks Mini about a fixture with a known answer two ways, unsandboxed: by URL and by decoded
//  CGImage. Both right → AFM can see, and the app's sandboxed URL hand-off is the suspect. Both
//  wrong → it's AFM's vision, not our plumbing.
//
//  Third arm (2026-10-09): the APP'S SHAPE, unsandboxed — persona instructions, a 16-tool
//  LanguageModelSession(tools:), the AFMToolPrompt-rendered body, Attachment(imageURL:). Reads the
//  total → the sandboxed file hand-off is the suspect (hypothesis A); confabulates → the prompt
//  shape makes AFM ignore the image (hypothesis B).
//
//  Bisect (2026-10-09, later): seven arms over persona × tools × steer × calling mode. Result: the
//  persona trips the guardrail ("May contain unsafe content"); ANY tool palette — generic
//  instructions, a steer, a hard "do not call a tool", even `.disallowed` — makes Mini call
//  read_document / search_knowledge instead of looking; "neutral, no tools, steer" reads €23.40.
//  The expectation pins the arm the app ships (`AFMToolPrompt.visionTurn`), whose body also drops
//  render's closing tool paragraph (with it, the tool-free arm said "Call the calculator tool with
//  the amount €23.40"). `M1K3_AFM_VISION_ARMS` ("a|b") runs a subset.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.7, Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-10-09 — added the app-shaped arm (persona + tools + rendered body).
//  Review: Kev + claude-fable-5.1, 2026-10-09 (2) — the seven-arm bisect; the shipped builder is the pinned arm.

import CoreGraphics
import Foundation
import ImageIO
@testable import M1K3Inference
import Testing
#if canImport(FoundationModels)
    @_weakLinked import FoundationModels
#endif

@Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_AFM_EVAL"] == "1"), .serialized)
struct AFMVisionLiveTests {
    /// receipt-cafe.png's total is 23.40 by construction (tools/eval/make_vision_fixtures.swift).
    private static let receipt = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/M1K3Eval/Resources/VisionFixtures/receipt-cafe.png")
    private static let question = "What's the total on this receipt? Reply with just the amount."

    #if compiler(>=6.4) && canImport(FoundationModels)
        @Test("Mini reads the receipt total by URL and by CGImage (prints both answers)")
        func miniReadsTheReceipt() async throws {
            guard #available(macOS 27.0, *) else { return }
            let availability = SystemLanguageModel.default.availability
            print("AFM-VISION availability=\(availability)")
            try #require(SystemLanguageModel.default.isAvailable, "Apple Intelligence: \(availability)")
            try #require(FileManager.default.fileExists(atPath: Self.receipt.path))

            let byURL = try await LanguageModelSession().respond {
                Self.question
                Attachment(imageURL: Self.receipt)
            }.content

            let source = try #require(CGImageSourceCreateWithURL(Self.receipt as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let byImage = try await LanguageModelSession().respond {
                Self.question
                Attachment(image)
            }.content

            print("AFM-VISION url=\(byURL.debugDescription) cgimage=\(byImage.debugDescription)")
            // The record is the printed pair; the expectation pins the CGImage path, which never
            // depends on another process reading our files.
            #expect(byImage.contains("23.40") || byImage.contains("23,40"), "cgimage: \(byImage)")
        }

        @Test("Mini reads the receipt in the APP's prompt shape (persona + 16 tools + rendered body)")
        func miniReadsTheReceiptInAppShape() async throws {
            guard #available(macOS 27.0, *) else { return }
            let availability = SystemLanguageModel.default.availability
            print("AFM-VISION-APP availability=\(availability)")
            try #require(SystemLanguageModel.default.isAvailable, "Apple Intelligence: \(availability)")
            try #require(FileManager.default.fileExists(atPath: Self.receipt.path))

            let names = [
                "search_knowledge", "remember", "recall", "web_search", "read_page", "get_time",
                "list_todos", "add_todo", "calendar_today", "read_document", "search_chats",
                "activity_digest", "weather", "calculator", "open_url", "summarize",
            ]
            let defs = names.map {
                ToolDefinition(
                    name: $0, description: "Representative \($0) tool for the vision shape probe.",
                    parameters: [ToolParameterDefinition(name: "query", description: "Input")]
                )
            }
            let tools = AFMNativeTool.wrap(defs) { _, _ in }
            let messages: [ToolMessage] = [
                .system(M1K3Persona.systemPrompt(variant: nil)),
                .user(Self.question, images: [ImageAttachment(url: Self.receipt)]),
            ]
            let body = AFMToolPrompt.render(messages: messages, tools: [])
            let urls = AFMToolPrompt.imageURLs(from: messages)
            let persona = AFMToolPrompt.systemInstructions(from: messages) ?? ""
            // Bisect: full shape first, then drop the persona, then drop the tools. An arm that
            // throws (guardrails) is a finding too — printed, not fatal, so the others still run.
            let neutral = "You are a helpful assistant. The user attached an image: read it and answer "
                + "from what you see. Your tools are for the user's notes, the web and the clock — call "
                + "one only when the question needs it."
            let steer = "An image is attached: describe it or answer from it first; call a tool only if "
                + "the question needs one."
            let hardSteer = "An image is attached. Answer from the image. Do not call a tool for this message."
            let shipped = try #require(AFMToolPrompt.visionTurn(from: messages, imagesAttachable: true))
            struct Arm {
                let label: String, instructions: String, tools: [AFMNativeTool], steer: String
                var mode: GenerationOptions.ToolCallingMode = .allowed
            }
            let arms: [Arm] = [
                Arm(label: "persona+tools", instructions: persona, tools: tools, steer: ""),
                Arm(label: "tools only", instructions: "You are a helpful assistant.", tools: tools, steer: ""),
                Arm(label: "persona only", instructions: persona, tools: [], steer: ""),
                Arm(label: "neutral+tools+steer", instructions: neutral, tools: tools, steer: steer),
                Arm(label: "neutral, no tools, steer", instructions: neutral, tools: [], steer: steer),
                Arm(label: "neutral+tools, calling disallowed", instructions: neutral, tools: tools, steer: steer,
                    mode: .disallowed),
                Arm(label: "neutral+tools, hard steer", instructions: neutral, tools: tools, steer: hardSteer),
                // What the app ships: the builder's own instructions and body, no tools.
                Arm(label: "shipped (visionTurn)", instructions: shipped.instructions, tools: [], steer: ""),
            ]
            let only = ProcessInfo.processInfo.environment["M1K3_AFM_VISION_ARMS"]?
                .split(separator: "|").map(String.init)
            var answers: [String: String] = [:]
            for arm in arms where only == nil || only!.contains(arm.label) {
                try await Task.sleep(for: .seconds(20))
                let session = LanguageModelSession(tools: arm.tools, instructions: arm.instructions)
                let armBody = arm.label.hasPrefix("shipped") ? shipped.body
                    : arm.steer.isEmpty ? body : body + "\n" + arm.steer
                do {
                    let answer = try await session.respond(options: GenerationOptions(toolCallingMode: arm.mode)) {
                        armBody
                        for url in urls {
                            Attachment(imageURL: url)
                        }
                    }.content
                    answers[arm.label] = answer
                    print("AFM-VISION-APP \(arm.label) answer=\(answer.debugDescription)")
                } catch {
                    print("AFM-VISION-APP \(arm.label) error=\(error)")
                }
            }
            // The arm the app ships is the one pinned; the others are the record of why.
            let routed = answers["shipped (visionTurn)"] ?? ""
            #expect(routed.contains("23.40") || routed.contains("23,40"), "app-shape: \(answers)")
        }
    #endif
}
