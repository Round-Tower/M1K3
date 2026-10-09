//
//  ImageCaptionerTests.swift
//  M1K3ChatTests
//
//  The orchestrator: a caption session never carries the persona (the
//  captioner sees the NEUTRAL instructions as the task-local override and runs
//  as background utility), refuses a wrong brain before touching the provider,
//  and reports -- never swallows -- a provider with no captioning capability.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8, Prior: Unknown

import Foundation
@testable import M1K3Chat
import M1K3Inference
import Testing

private final class SpyCaptioner: InferenceProvider, ImageCaptioning, @unchecked Sendable {
    let name = "spy"
    let isAvailable = true
    private let lock = NSLock()
    private(set) var instructionsSeen: String?
    private(set) var backgroundSeen = false
    private(set) var promptSeen: String?
    var reply = "A whiteboard listing three pricing tiers."

    func generate(prompt _: String) async throws -> String {
        ""
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func caption(image _: ImageAttachment, prompt: String) async throws -> String {
        lock.withLock {
            instructionsSeen = InferenceIntent.instructions
            backgroundSeen = InferenceIntent.isBackgroundUtility
            promptSeen = prompt
        }
        return reply
    }
}

private struct TextOnlyProvider: InferenceProvider {
    let name = "text-only"
    let isAvailable = true
    func generate(prompt _: String) async throws -> String {
        ""
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

struct ImageCaptionerTests {
    private let image = ImageAttachment(url: URL(fileURLWithPath: "/tmp/whiteboard.png"))

    @Test("the caption runs under the neutral instructions, as background utility")
    func neutralAndBackground() async throws {
        let spy = SpyCaptioner()
        let caption = try await ImageCaptioner(provider: spy).caption(image: image, tier: .lil)
        #expect(caption == "A whiteboard listing three pricing tiers.")
        #expect(spy.instructionsSeen == ImageCaptionPolicy.neutralInstructions)
        #expect(spy.backgroundSeen)
        #expect(spy.promptSeen == ImageCaptionPolicy.prompt)
    }

    @Test("a refused brain never reaches the provider")
    func refusedBeforeProvider() async {
        let spy = SpyCaptioner()
        await #expect(throws: ImageCaptioner.Failure.self) {
            try await ImageCaptioner(provider: spy).caption(image: image, tier: .mini)
        }
        #expect(spy.promptSeen == nil)
    }

    @Test("a provider without the capability is reported, not silently skipped")
    func unavailableProvider() async {
        await #expect(throws: ImageCaptioner.Failure.unavailable) {
            try await ImageCaptioner(provider: TextOnlyProvider()).caption(image: image, tier: .lil)
        }
    }

    @Test("an unusable caption (refusal) is an error, never stored")
    func unusableCaption() async {
        let spy = SpyCaptioner()
        spy.reply = "I can't describe this."
        await #expect(throws: ImageCaptioner.Failure.unusable) {
            try await ImageCaptioner(provider: spy).caption(image: image, tier: .big)
        }
    }

    @Test("the captioner sees through the swappable façade")
    func throughFacade() async throws {
        let spy = SpyCaptioner()
        let caption = try await ImageCaptioner(provider: SwappableInferenceProvider(spy)).caption(image: image, tier: .lil)
        #expect(!caption.isEmpty)
        #expect(spy.instructionsSeen == ImageCaptionPolicy.neutralInstructions)
    }
}
