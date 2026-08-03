//
//  MiniPromptBudgetTests.swift
//  M1K3ChatTests
//
//  Mini (Apple Foundation Models) has a 4096-token context window — HALF what
//  the MLX tiers carry. Observed live on 2026-08-03, interviewing Mini over MCP:
//
//    GenerationError.exceededContextWindowSize
//    "Content contains 4486 tokens, which exceeds the maximum allowed
//     context size of 4096."
//
//  The turn that threw had `grounding=8263 chars` from 5 retrieved chunks, on
//  the question "Why is the sky blue?". Four of seven conversational probes in
//  that interview never answered at all — they hit the 120s MCP deadline while
//  the agent loop ground through an over-stuffed prompt.
//
//  These tests pin the size contract for the tier, so a prompt change that
//  cannot fit Mini fails here rather than in a user's chat.
//
//  Signed: Kev + claude-opus-5, 2026-08-03, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

struct MiniPromptBudgetTests {
    /// Apple Foundation Models' hard ceiling, quoted verbatim by the SDK error.
    static let miniContextWindow = 1024 * 4

    /// Shared with the live budget rather than restated, so the two can't drift:
    /// a second hardcoded 4.4 here would let this suite keep passing against a
    /// figure the cap no longer uses.
    static func estimatedTokens(_ text: String) -> Int {
        GroundingBudget.estimatedTokens(text)
    }

    @Test("the standing persona alone leaves Mini room to work")
    func personaFitsWithHeadroom() {
        // Mini gets the COMPACT core (no voiceExemplars — those ride only where
        // a KV-cached prefix makes them free). Whatever else changes, the
        // always-on part of the prompt must not eat the window on its own.
        let persona = M1K3Persona.systemPrompt(includeExemplars: false)
        let tokens = Self.estimatedTokens(persona)
        #expect(
            tokens < Self.miniContextWindow / 3,
            """
            The compact persona is ~\(tokens) tokens of Mini's \
            \(Self.miniContextWindow)-token window (\(persona.count) chars). \
            Over a third of the window before the turn has any content in it \
            leaves too little for grounding, history, the question and the answer.
            """
        )
    }

    @Test("the full persona with exemplars would still fit Mini's window")
    func exemplarsWouldFit() {
        // The register question: Mini is the DEFAULT brain and the only tier
        // that never sees voiceExemplars, which is the strongest voice signal
        // M1K3 has. This does not argue they should ship there — that is a
        // measured A/B call — but it pins the cost so the decision is made on
        // numbers rather than on an assumption about affordability.
        let compact = Self.estimatedTokens(M1K3Persona.systemPrompt(includeExemplars: false))
        let full = Self.estimatedTokens(M1K3Persona.systemPrompt(includeExemplars: true))
        let exemplarCost = full - compact
        #expect(
            exemplarCost < 300,
            "voiceExemplars cost ~\(exemplarCost) estimated tokens on top of ~\(compact)."
        )
        #expect(full < Self.miniContextWindow / 2)
    }
}
