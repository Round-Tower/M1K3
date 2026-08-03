//
//  PromptContext.swift
//  M1K3Chat
//
//  A compact per-turn "what's true right now" line for the agent grounding.
//
//  Two honest facts small models otherwise get wrong:
//    • the PRECISE date — weekday + day. The cached persona prefix carries only
//      month+year (kept coarse so the persona-prefix KV cache lives a whole month,
//      see M1K3Persona.currentDateLine), so without this the model can't say what
//      DAY it is — it guesses, or pleads "no real-time data".
//    • WHICH brain is answering. mini/lil/big all share one persona, so the
//      model otherwise can't honestly answer "which model are you?".
//
//  It lives in the PER-TURN grounding, NOT the cached persona prefix — so it
//  never busts the persona-prefix KV cache (a TTFT tax) or drifts the persona-LoRA
//  baseline (trained against the current prefix). Pure + tested; the responder
//  prepends it with `Date()` and the live brain name at turn time.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-21, Confidence 0.85 (textbook date
//  formatting; the cache/LoRA-safe placement is the load-bearing call). Prior: Unknown.
//  Review: Kev + claude-opus-5, 2026-08-03, Confidence 0.9 — "and you're \(brain)"
//  turned the TIER NAME into an identity claim, and being nearer the question
//  than the persona, it won: interviewed over MCP, Mini answered "who are you?"
//  with "I'm Mini, an AI living on this Mac". The live value is
//  BrainTier.displayName — bare "Mini"/"Lil"/"Big", internal vocabulary the user
//  has never heard — while this file's own test fixture used the friendlier
//  "Lil M1K3", which is why the phrasing read fine here and broke in production.
//  Now: M1K3 THINKS WITH a brain, it is not the brain. Third instance of one
//  pattern (see #97's "private local assistant"): a per-turn line asserting an
//  identity the persona already owns.

import Foundation
import M1K3Inference

public enum PromptContext {
    /// The grounding line for `now`, naming `brainName` if known. English names,
    /// host-locale-independent. An empty/blank brain name drops the brain clause.
    public static func line(now: Date, brainName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX") // stable English names
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        let date = formatter.string(from: now)
        let brain = brainName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brain.isEmpty else {
            return "Right now (true for this turn): it's \(date)."
        }
        // The brain is what M1K3 THINKS WITH, never what it IS. "you're \(brain)"
        // made the tier name an identity claim, and since it sits closer to the
        // question than the persona does, it won: Mini introduced itself as
        // "I'm Mini, an AI living on this Mac" (MCP interview, 2026-08-03). A
        // tier name is internal vocabulary the user has never heard.
        return "Right now (true for this turn): it's \(date). You're M1K3, thinking with your "
            + "\(brain) brain — running entirely on \(HostPlatform.thisDevice)."
    }
}
