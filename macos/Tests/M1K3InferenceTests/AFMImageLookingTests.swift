//
//  AFMImageLookingTests.swift
//  M1K3InferenceTests
//
//  Mini's side of the look seam (#768). The pure pins run everywhere: Mini
//  conforms, blank instructions never fall back to a persona, and a failed
//  look turns into a reply that fits the failure instead of a guess. The live
//  arm is opt-in (`M1K3_AFM_EVAL=1`, macOS 27 with Apple Intelligence): the
//  provider's own stream reads the receipt fixture's total.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.8, Prior: none (new file)

import Foundation
@testable import M1K3Inference
import Testing

struct AFMImageLookingTests {
    @Test("Mini conforms to the look capability")
    func miniLooks() {
        #expect((AppleFoundationModelsProvider() as Any) is ImageLooking)
    }

    @Test("look instructions are trimmed, and blank ones are an error: no persona fallback")
    func instructionsRefuseBlank() throws {
        #expect(try ImageLookingError.instructions("  Look.\n") == "Look.")
        #expect(throws: InferenceError.self) { try ImageLookingError.instructions(" \n") }
    }

    @Test("a look that fails for a passing reason asks for another try, without a brain switch")
    func transientFailuresAskForARetry() {
        for failure in [AFMFailure.rateLimited, .daemonUnavailable, .timeout, .contextOverflow] {
            let reply = LookFailureReply.reply(for: failure, readers: [.lil])
            #expect(reply == LookFailureReply.tryAgain, "\(failure)")
        }
    }

    @Test("a guardrail or unplaced failure declines to guess and names the brain that can look")
    func guardrailDeclinesAndNamesAReader() {
        for failure in [AFMFailure.guardrailViolation, .unknown] {
            let reply = LookFailureReply.reply(for: failure, readers: [.lil])
            #expect(reply.contains("won't guess"), "\(failure)")
            #expect(reply.contains(BrainTier.lil.displayName), "\(failure)")
        }
        let alone = LookFailureReply.reply(for: .guardrailViolation, readers: [])
        #expect(alone.contains("won't guess"))
        #expect(!alone.contains("Switch"))
    }

    @Test("a language Apple's model doesn't speak gets the one unsupported-language reply")
    func unsupportedLanguage() {
        #expect(LookFailureReply.reply(for: .unsupportedLanguage, readers: [.lil]) == AFMFailure.unsupportedLanguageReply)
    }

    @Test("every failure class has a reply, and none is empty")
    func everyClassReplies() {
        for failure in AFMFailure.allCases {
            #expect(!LookFailureReply.reply(for: failure, readers: [.lil]).isEmpty, "\(failure)")
        }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_AFM_EVAL"] == "1"), .serialized)
struct AFMImageLookingLiveTests {
    /// receipt-cafe.png's total is 23.40 by construction (tools/eval/make_vision_fixtures.swift).
    private static let receipt = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/M1K3Eval/Resources/VisionFixtures/receipt-cafe.png")

    @Test("Mini's look streams cumulative snapshots and reads the receipt total")
    func miniLooksAtTheReceipt() async throws {
        let provider = AppleFoundationModelsProvider()
        try #require(provider.isAvailable, "Apple Intelligence is not available here")
        try #require(AFMToolPrompt.imagesAttachable)
        try #require(FileManager.default.fileExists(atPath: Self.receipt.path))
        let clock = ContinuousClock()
        let start = clock.now
        var first: Duration?
        var snapshots: [String] = []
        let stream = provider.look(
            image: ImageAttachment(url: Self.receipt),
            instructions: "You are looking at a photo for the person who took it. Answer briefly, from what you can see.",
            prompt: "What's the total on this receipt? Reply with just the amount."
        )
        for try await snapshot in stream {
            if first == nil, !snapshot.isEmpty { first = clock.now - start }
            snapshots.append(snapshot)
        }
        let answer = snapshots.last ?? ""
        print("AFM-LOOK first=\(String(describing: first)) total=\(clock.now - start) snapshots=\(snapshots.count) answer=\(answer.debugDescription)")
        #expect(answer.contains("23.40") || answer.contains("23,40"), "look: \(answer)")
        // Cumulative: each snapshot extends (or revises) the one before; the last is the longest read.
        #expect(snapshots.count >= 1)
    }
}
