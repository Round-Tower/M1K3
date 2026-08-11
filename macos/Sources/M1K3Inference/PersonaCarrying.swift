//
//  PersonaCarrying.swift
//  M1K3Inference
//
//  A capability seam: "this backend already carries M1K3's persona as standing
//  instructions, so don't put it in the prompt body as well."
//
//  Why it exists. The ReAct floor prepends `M1K3Persona.systemPrompt` to every
//  prompt because a bare completion backend has nowhere else to learn who it
//  is. `AppleFoundationModelsProvider`, though, opens a fresh
//  `LanguageModelSession(instructions:)` per call with that same persona — so
//  the pairing that actually ships (Mini runs the ReAct floor;
//  `nativeToolCalling` is default-OFF) sent the persona TWICE, ~890 tokens
//  each, against Mini's 4096-token window. Roughly 43% of the smallest window
//  on the ladder, spent restating identity before the question existed — on the
//  tier every new user meets first.
//
//  It hid because the budget test that should have caught it,
//  `MiniPromptBudgetTests`, measures the persona in ISOLATION. A component-level
//  budget assertion is structurally incapable of seeing a duplication bug; only
//  an assembled-prompt assertion can (ReActPersonaDuplicationTests).
//
//  Modelled on `ToolCallingProvider` / `TokenCounting`: a separate protocol
//  reached by `as?`, never a new requirement on `InferenceProvider`. Not
//  conforming is the safe default — an unaware backend keeps the persona in its
//  body and behaves exactly as before, so this can never silently strip a
//  model's identity.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.9, Prior: Unknown
//  Context: macos/docs/NEXT_SESSION.md #102. Surfaced by `challenger` while
//  pressure-testing the small-talk gate, then verified against source
//  (LocalAgent+ReAct.buildInitialContext vs AppleFoundationModelsProvider).
//

import Foundation

/// Implemented by backends that inject M1K3's persona themselves — as a system
/// role, standing session instructions, or a cached KV prefix — so callers can
/// avoid sending it a second time in the prompt body.
public protocol PersonaCarrying: Sendable {
    /// `true` when every generation from this backend already carries the
    /// persona. A property rather than a marker protocol because AFM's own
    /// `instructions` closure is injectable: secondary jobs (the memory
    /// distiller, future judges) pass NEUTRAL instructions precisely so they
    /// don't speak as M1K3, and those sessions genuinely are not carrying it.
    var carriesStandingPersona: Bool { get }
}
