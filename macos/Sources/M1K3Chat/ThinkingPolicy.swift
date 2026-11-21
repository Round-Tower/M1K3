//
//  ThinkingPolicy.swift
//  M1K3Chat
//
//  Per-turn reasoning budget: Qwen3.5's think phase is gold on hard questions
//  and a 30-second tax on "yo, what's up?". Auto mode decides from cheap
//  signals — grounding present, analytic verbs, length — and the Settings
//  override (Always think / Fast answers) always wins. Fast turns render
//  no reasoning disclosure at all, honestly: nothing was thought.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.8 (heuristic is a
//  starting point — tune on real turns). Prior: Unknown
//  Review: Kev + claude-opus-4-8, 2026-06-29, Confidence 0.85 — the per-tier
//  fast default (df73a25a) removed only the "grounded ⇒ think" trigger, so the
//  broad substring markers ("how"/"why") and the 12-word length fallback still
//  fired thinking on nearly every UI message — "fast" was a lie and codegen
//  ("write"/"code") forced a think phase that ate the token budget the artifact
//  needs (the "refuses to code" bug). Fix: generation verbs are no longer
//  "analytic" on any tier, and the speed tier now thinks ONLY on an explicit
//  deep-reasoning marker (no weak openers, no length). Verify-by-feel at ⌘R.
//  Review: Kev + claude-fable-5.1, 2026-10-09 — `ThinkingModeResolver`: the Mac's
//  inline provider closure became a shared pure function so the iOS shell reads
//  the same default, keys and voice-fast rule (#198).
//  Review: Kev + claude-opus-5-5, 2026-10-18 — `thinkingBudgetCharacters`: the think phase's cap.
//  Confidence 0.7 — the figure is ~1,000 tokens, chosen before the capped arm ran; see its doc.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — the doc says a forcing brain (Lil since today) replaces the figure
//  each turn with a net above its budget. Comment only.
//  Review: Kev + claude-opus-5-5, 2026-11-20 — `shape: ThinkingShapeMode` (default `.off`, today's policy) and
//  `stepsClause`: the A/B arms Kev asked for after the 11-19 diagnostic. `think` lets a speed tier think on a
//  `PuzzleShape` turn or a wave-one "explain" ask; `steps` keeps the think phase off and adds a work-in-steps clause
//  on a puzzle. Off by default: nothing changes until the arm wins. Confidence 0.75.
//

import Foundation

/// The Settings-facing reasoning preference.
public enum ThinkingMode: String, CaseIterable, Sendable {
    case auto
    case always
    case fast
}

/// Voice mode's own brain switch. While the spoken loop is active the in-mode
/// toggle REPLACES the Settings preference — latency is the UX there, so off
/// (the default) forces fast even over an explicit Always, and on yields auto
/// so the per-turn heuristics still skip the think phase on small talk.
/// Outside voice mode the toggle is inert and the stored setting governs.
public enum VoiceThinkingPolicy {
    public static func effectiveMode(
        stored: ThinkingMode,
        voiceModeActive: Bool,
        voiceThinkingEnabled: Bool
    ) -> ThinkingMode {
        guard voiceModeActive else { return stored }
        return voiceThinkingEnabled ? .auto : .fast
    }
}

/// The per-turn mode resolution BOTH shells read (#198): the Mac's
/// `AppEnvironment` and the iOS `AppCore` each pass `resolve` as their
/// `thinkingModeProvider`, so the default (auto), the defaults keys and the
/// voice "fast" rule cannot drift apart. iOS has no Reasoning picker, so its
/// stored value is always unset and the default governs; a Qwen3.5 brain
/// (Lil) reads `enable_thinking` from the resolved mode.
public enum ThinkingModeResolver {
    /// What an unset (or unreadable) stored value means.
    public static let defaultMode: ThinkingMode = .auto
    /// UserDefaults key of the Settings Reasoning picker (a `ThinkingMode` rawValue).
    public static let storedModeKey = "thinkingMode"
    /// UserDefaults key of voice mode's in-mode thinking toggle (default off → fast).
    public static let voiceThinkingKey = "voiceMode.thinking"

    public static func resolve(
        storedRaw: String?,
        forced: ThinkingMode?,
        voiceModeActive: Bool,
        voiceThinkingEnabled: Bool
    ) -> ThinkingMode {
        if let forced { return forced }
        let stored = storedRaw.flatMap(ThinkingMode.init(rawValue:)) ?? defaultMode
        return VoiceThinkingPolicy.effectiveMode(
            stored: stored,
            voiceModeActive: voiceModeActive,
            voiceThinkingEnabled: voiceThinkingEnabled
        )
    }
}

enum ThinkingPolicy {
    /// How much open reasoning a plain or dispatched turn may stream before it is cut and
    /// answered straight (`AgentRAGResponder.runPlainTurn`). About 1,000 tokens at ~4 chars a
    /// token. Measured 2026-10-17 on Lil, Always-think against Auto: chat 34/39 both, reasoning,
    /// code, knowledge and instruction asks 28/30 both, at ~145–180 s a turn against ~15 s. Lil
    /// thought 2,500–4,500 tokens before answering a sum, and never closed under ~1,400 on chat,
    /// so a cap this size cuts most think phases short: the shown thought is the price of a
    /// bounded turn. The agent loop's tool turns are not capped here. A brain that forces its own
    /// close (`ThinkBudgetForcing`: Lil at 1,024 tokens since 2026-10-19) replaces this each turn
    /// with a net above its budget (`ThinkBudget.characterCap(forTokens:)`, 8,192 for Lil), so this
    /// figure governs the other brains, and Lil only under `-thinkBudgetTokens 0`.
    static let thinkingBudgetCharacters = 4000

    /// Words at or above which a question earns the think phase regardless
    /// of other signals.
    private static let longQuestionWordCount = 12

    /// Analytic markers — asks that benefit from chain-of-thought even when
    /// short. Matched as SUBSTRINGS (not word prefixes) on purpose — "analy"
    /// catches analyse/analyze/analysis. GENERATION verbs ("write"/"code") are
    /// deliberately NOT here: producing an artifact is a task to DO, not a
    /// reasoning ask, and a forced think phase eats the token budget the artifact
    /// itself needs (the "refuses to code" bug). Used on the heavier tiers only.
    private static let analyticMarkers = [
        "why", "how", "explain", "compare", "analy", "plan", "debug",
        "calculate", "summar", "review", "design",
    ]

    /// The narrow set the SPEED tiers (Mini/Lil) think on. Only an explicit
    /// deep-reasoning ask earns the think tax there — never a weak opener
    /// ("how"/"why"), generation, or mere length, all of which fired on nearly
    /// every message and made "fast" a lie. Want CoT on a quick brain? Toggle
    /// Always-think, or pick a heavier brain.
    private static let strongAnalyticMarkers = [
        "explain", "compare", "analy", "debug", "step by step", "reason through",
    ]

    /// - Parameter fastByDefault: the active brain biases toward speed (Mini/Lil).
    ///   When true, the blanket "grounding present ⇒ think" rule is dropped: a plain
    ///   fact lookup on the speed tier shouldn't pay the think tax. Genuinely
    ///   analytic or long asks STILL think (the signals below). Heavier tiers
    ///   (false) keep grounded ⇒ think, where CoT earns its keep on citations.
    static func shouldThink(
        question: String,
        hasGroundedKnowledge: Bool,
        mode: ThinkingMode,
        fastByDefault: Bool = false,
        shape: ThinkingShapeMode = .off
    ) -> Bool {
        switch mode {
        case .always: return true
        case .fast: return false
        case .auto: break
        }
        let lowered = question.lowercased()
        if fastByDefault {
            // Speed tier: bias hard to fast. Only an explicit deep-reasoning ask
            // earns CoT — not grounding, not a weak opener, not length. The `think` arm
            // adds a puzzle-shaped turn and the wave-one twins of those asks.
            if strongAnalyticMarkers.contains(where: { lowered.contains($0) }) { return true }
            // Both arms: a wave-one "explain / step by step" ask thinks like the English one (language parity,
            // not the variable under test). The `think` arm also thinks on a puzzle.
            if shape != .off, PuzzleShape.asksForReasoning(question) { return true }
            return shape == .think && PuzzleShape.detects(question)
        }
        // Heavier tiers: grounding, an analytic verb, or length all earn CoT.
        if hasGroundedKnowledge { return true }
        if analyticMarkers.contains(where: { lowered.contains($0) }) { return true }
        let words = lowered.split(whereSeparator: \.isWhitespace).count
        return words >= longQuestionWordCount
    }

    /// The `steps` arm's turn clause: a puzzle-shaped turn that is NOT thinking is told to work in
    /// short steps before it answers, so the reasoning lands in the answer instead of a think phase.
    /// nil on every other arm, on Always / Fast, on a turn that thinks anyway, and off the shape.
    static func stepsClause(
        question: String, mode: ThinkingMode, shape: ThinkingShapeMode, thinking: Bool, fastByDefault: Bool
    ) -> String? {
        // A speed-tier arm: a heavier brain thinks on its own signals and never gets the clause.
        guard shape == .steps, mode == .auto, fastByDefault, !thinking, PuzzleShape.detects(question) else { return nil }
        return stepsClauseText
    }

    /// One instruction, English like every prompt clause; the reply-language clause after it
    /// sets the language the steps come back in.
    static let stepsClauseText =
        "This is a multi-step problem. Before you answer, work it out in a few short numbered steps, "
            + "checking each one; then give the answer on its own line."
}
