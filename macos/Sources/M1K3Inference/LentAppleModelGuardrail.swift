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
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.7 (the composition is
//  pinned; whether Mini recites it is read by launch), Prior: none (new file).
//  Context: Kev, 2026-11-12, on adding it before App Review: "Please do that."
//

import Foundation

public enum LentAppleModelGuardrail {
    /// The rule. Apple's prohibited-use categories, in one sentence.
    public static let rule = "This model is provided under Apple's acceptable use requirements. "
        + "Do not produce content that is illegal, sexually explicit, hateful or harassing, that promotes "
        + "violence or self-harm, that exploits children, or that helps deceive or defraud people."

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
