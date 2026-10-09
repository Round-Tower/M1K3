//
//  VoiceThinkingPolicyTests.swift
//  M1K3ChatTests
//
//  Voice mode owns its own brain switch: latency IS the UX in a spoken loop,
//  so the in-mode toggle REPLACES the global Reasoning setting while active —
//  off (default) → fast, on → auto (heuristics still skip small talk).
//  Outside voice mode the toggle is inert and Settings governs.
//
//  Signed: Kev + claude-fable-5, 2026-06-12, Confidence 0.9, Prior: Unknown
//

@testable import M1K3Chat
import Testing

struct VoiceThinkingPolicyTests {
    @Test("outside voice mode the stored setting passes through untouched")
    func storedGovernsOutsideVoiceMode() {
        for stored in ThinkingMode.allCases {
            #expect(VoiceThinkingPolicy.effectiveMode(
                stored: stored, voiceModeActive: false, voiceThinkingEnabled: false
            ) == stored)
            // The voice toggle is inert outside voice mode.
            #expect(VoiceThinkingPolicy.effectiveMode(
                stored: stored, voiceModeActive: false, voiceThinkingEnabled: true
            ) == stored)
        }
    }

    @Test("voice mode with thinking off forces fast — even over an explicit Always")
    func voiceModeDefaultIsFast() {
        for stored in ThinkingMode.allCases {
            #expect(VoiceThinkingPolicy.effectiveMode(
                stored: stored, voiceModeActive: true, voiceThinkingEnabled: false
            ) == .fast)
        }
    }

    @Test("voice mode with thinking on yields auto — heuristics decide per turn")
    func voiceModeThinkingOnIsAuto() {
        for stored in ThinkingMode.allCases {
            #expect(VoiceThinkingPolicy.effectiveMode(
                stored: stored, voiceModeActive: true, voiceThinkingEnabled: true
            ) == .auto)
        }
    }
}

/// The one resolution both shells read (#198): the Mac and the phone must agree on
/// the default, on the key, and on the voice "fast" rule.
struct ThinkingModeResolverTests {
    @Test("an unset or garbled stored value resolves to the shared default, auto")
    func defaultIsAuto() {
        #expect(ThinkingModeResolver.defaultMode == .auto)
        for raw in [nil, "", "nonsense"] as [String?] {
            #expect(ThinkingModeResolver.resolve(
                storedRaw: raw, forced: nil, voiceModeActive: false, voiceThinkingEnabled: false
            ) == .auto)
        }
    }

    @Test("a stored raw value round-trips outside voice mode")
    func storedPassesThrough() {
        for mode in ThinkingMode.allCases {
            #expect(ThinkingModeResolver.resolve(
                storedRaw: mode.rawValue, forced: nil, voiceModeActive: false, voiceThinkingEnabled: false
            ) == mode)
        }
    }

    @Test("voice mode with the toggle off is fast on a fresh install (no stored value)")
    func voiceIsFastByDefault() {
        #expect(ThinkingModeResolver.resolve(
            storedRaw: nil, forced: nil, voiceModeActive: true, voiceThinkingEnabled: false
        ) == .fast)
    }

    @Test("a forced mode bypasses Settings and voice mode alike")
    func forcedWins() {
        #expect(ThinkingModeResolver.resolve(
            storedRaw: "always", forced: .fast, voiceModeActive: false, voiceThinkingEnabled: true
        ) == .fast)
        #expect(ThinkingModeResolver.resolve(
            storedRaw: "fast", forced: .always, voiceModeActive: true, voiceThinkingEnabled: false
        ) == .always)
    }

    @Test("the defaults keys are pinned — a rename would silently orphan stored settings")
    func keysPinned() {
        #expect(ThinkingModeResolver.storedModeKey == "thinkingMode")
        #expect(ThinkingModeResolver.voiceThinkingKey == "voice" + "Mode.thinking")
    }
}
