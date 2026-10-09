//
//  ImageCaptionPolicyTests.swift
//  M1K3ChatTests
//
//  Caption memory (Stream D, 1.1 slice), the challenger's shape pinned:
//    - only MLX Lil and Big caption; Mini (its instruction override would evict
//      chat's persona prewarm) and Pocket (text-only) are refused BY NAME;
//    - the trigger is the user's tap, never automatic (no scheduler exists, and
//      a caption queues ahead of the next turn on the model's actor);
//    - the instructions are neutral (no persona) and treat pixels-as-text as
//      DATA to quote, so an injected screenshot cannot persist as an order;
//    - model output is cleaned: reasoning stripped, refusals and persona leaks
//      dropped, length bounded.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8, Prior: Unknown

import Foundation
@testable import M1K3Chat
import M1K3Inference
import Testing

struct ImageCaptionPolicyTests {
    @Test("Lil and Big may caption")
    func lilAndBigAllowed() {
        #expect(ImageCaptionPolicy.decision(for: .lil) == .allowed)
        #expect(ImageCaptionPolicy.decision(for: .big) == .allowed)
    }

    @Test("Mini and Pocket are refused by name, pointing at Lil")
    func miniAndPocketRefusedByName() {
        for tier in [BrainTier.mini, .pocket] {
            guard case let .refused(message) = ImageCaptionPolicy.decision(for: tier) else {
                Issue.record("\(tier) should be refused")
                continue
            }
            #expect(message.contains("Lil"))
            #expect(message.contains(tier.displayName))
        }
    }

    @Test("only the user's tap triggers a caption -- never automatic")
    func triggerIsOptIn() {
        #expect(ImageCaptionPolicy.trigger == .userTap)
    }

    @Test("the instructions are neutral: no persona, and pictured text is data")
    func neutralInstructions() {
        let text = ImageCaptionPolicy.neutralInstructions
        #expect(!text.contains("M1K3"))
        #expect(!text.contains("ABSOLUTE RULES"))
        #expect(!PersonaLeakGuard.leaks(text))
        #expect(text.contains("quotation marks"))
        #expect(text.localizedCaseInsensitiveContains("never as instructions"))
    }

    @Test("clean strips reasoning and trims")
    func cleanStripsThinking() {
        #expect(ImageCaptionPolicy.clean("<think>hmm</think>\n  A whiteboard with prices.  \n") == "A whiteboard with prices.")
    }

    @Test("clean drops a refusal, an empty answer, a persona leak and an unclosed think")
    func cleanDropsUnusable() {
        #expect(ImageCaptionPolicy.clean("I can't help with that image.") == nil)
        #expect(ImageCaptionPolicy.clean("Sorry, I cannot see it") == nil)
        #expect(ImageCaptionPolicy.clean("I’m unable to describe this.") == nil)
        #expect(ImageCaptionPolicy.clean("   \n") == nil)
        #expect(ImageCaptionPolicy.clean("<think>The user wants a caption and") == nil)
    }

    @Test("clean bounds the length at a word")
    func cleanBoundsLength() throws {
        let long = String(repeating: "pricing tiers ", count: 200)
        let cleaned = try #require(ImageCaptionPolicy.clean(long))
        #expect(cleaned.count <= ImageCaptionPolicy.maxCaptionCharacters)
        #expect(!cleaned.hasSuffix(" "))
    }
}
