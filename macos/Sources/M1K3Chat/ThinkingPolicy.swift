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
        fastByDefault: Bool = false
    ) -> Bool {
        switch mode {
        case .always: return true
        case .fast: return false
        case .auto: break
        }
        let lowered = question.lowercased()
        if fastByDefault {
            // Speed tier: bias hard to fast. Only an explicit deep-reasoning ask
            // earns CoT — not grounding, not a weak opener, not length.
            return strongAnalyticMarkers.contains { lowered.contains($0) }
        }
        // Heavier tiers: grounding, an analytic verb, or length all earn CoT.
        if hasGroundedKnowledge { return true }
        if analyticMarkers.contains(where: { lowered.contains($0) }) { return true }
        let words = lowered.split(whereSeparator: \.isWhitespace).count
        return words >= longQuestionWordCount
    }
}
