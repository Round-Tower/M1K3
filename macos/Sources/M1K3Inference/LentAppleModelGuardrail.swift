//
//  LentAppleModelGuardrail.swift
//  M1K3Inference
//
//  The one line of M1K3's own that rides ahead of a caller's instructions when
//  an APPLE model is lent to another app (Mini on the Local API; Private Cloud
//  Compute on the Local API and through MCP). Apple's Developer Program License
//  Agreement, section 3.3.11 A, asks a developer "to follow, and to maintain
//  reasonable guardrails supporting, the Foundation Models Framework Acceptable
//  Use Requirements". Apple's own safety filter stays in force; this is ours,
//  on top (ADR 0011).
//
//  Not applied to Lil or Big (MLX models, not Apple's), and not to M1K3's own
//  chat, whose persona carries its own rules.
//
//  Worded as a rule with no reply to give: Mini once copied a spelled-out
//  decline onto ordinary coding questions (#799).
//
//  Measured live on Mini, 2026-11-12 (ten ordinary asks a round, four of them
//  under a caller's system prompt). A first wording that listed Apple's
//  categories by name was refused by Apple's safety filter on 3 of 10 ("May
//  contain unsafe content": a haiku about rain, the colour of the sky), against
//  1 of 40 with no rule at all. This wording: 0 of 40 refused, 0 echoed in an
//  answer, and the caller's own instruction still obeyed 4 of 4.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.75 (the composition
//  is pinned and the wording measured on Mini; the cloud model is untried with
//  it), Prior: none (new file).
//  Context: Kev, 2026-11-12, on adding it before App Review: "Please do that."
//

import Foundation

public enum LentAppleModelGuardrail {
    /// The rule. It names the requirements and four broad kinds of content, and no more: spelling out
    /// Apple's categories (explicit, violent, and so on) made Apple's own safety filter refuse ordinary asks.
    public static let rule = "This model is provided under Apple's acceptable use requirements for the "
        + "Foundation Models framework. Keep every answer within them: nothing unlawful, harmful, hateful "
        + "or deceptive."

    /// Hands over to the caller's own instructions.
    public static let handover = "Within that, follow these instructions:"

    /// The instructions a lent Apple model runs under: the rule, then the caller's own text, whole.
    public static func instructions(callerSystem: String?) -> String {
        guard let caller = callerSystem, !caller.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rule
        }
        return rule + "\n\n" + handover + "\n" + caller
    }
}
