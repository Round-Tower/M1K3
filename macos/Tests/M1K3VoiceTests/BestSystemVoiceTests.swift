//
//  BestSystemVoiceTests.swift
//  M1K3VoiceTests
//
//  #584 / #576 §3: Built-in should never speak in the compact voice when a better
//  one is installed. The pick is pure: premium > enhanced, the locale's region
//  before its language, deterministic ties — and NO pick (the system's own
//  default) when only compact voices exist, because the system default already
//  is one and a novelty voice would be worse.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-13, Confidence 0.9 (pure, total).
//  Prior: none (new file).
//

import Foundation
@testable import M1K3Voice
import Testing

struct BestSystemVoiceTests {
    private func voice(
        _ id: String, _ language: String, _ quality: SystemVoiceCandidate.Quality
    ) -> SystemVoiceCandidate {
        SystemVoiceCandidate(identifier: id, language: language, quality: quality)
    }

    private let ie = Locale(identifier: "en_IE")

    @Test("premium beats enhanced beats compact")
    func qualityWins() {
        let voices = [
            voice("compact", "en-IE", .compact),
            voice("premium", "en-IE", .premium),
            voice("enhanced", "en-IE", .enhanced),
        ]
        #expect(BestSystemVoice.pick(voices: voices, locale: ie) == "premium")
        #expect(BestSystemVoice.pick(voices: Array(voices.prefix(1)) + [voices[2]], locale: ie) == "enhanced")
    }

    @Test("the locale's region wins within a quality; its language is next")
    func regionBeforeLanguage() {
        let voices = [
            voice("en-US-premium", "en-US", .premium),
            voice("en-IE-premium", "en-IE", .premium),
            voice("en-GB-premium", "en-GB", .premium),
        ]
        #expect(BestSystemVoice.pick(voices: voices, locale: ie) == "en-IE-premium")
        // No home voice: any region, by identifier — never nil while a good voice exists.
        #expect(BestSystemVoice.pick(voices: voices, locale: Locale(identifier: "en_AU")) == "en-GB-premium")
    }

    @Test("a better voice in another region beats a compact one at home")
    func qualityBeatsRegion() {
        let voices = [voice("ie-compact", "en-IE", .compact), voice("gb-enhanced", "en-GB", .enhanced)]
        #expect(BestSystemVoice.pick(voices: voices, locale: ie) == "gb-enhanced")
    }

    @Test("only compact voices: no pick — the system default is already one")
    func compactOnlyLeavesTheDefault() {
        let voices = [voice("a", "en-IE", .compact), voice("zarvox", "en-US", .compact)]
        #expect(BestSystemVoice.pick(voices: voices, locale: ie) == nil)
    }

    @Test("never a voice in another language, however good")
    func languageIsAHardWall() {
        let voices = [voice("fr-premium", "fr-FR", .premium), voice("de-enhanced", "de-DE", .enhanced)]
        #expect(BestSystemVoice.pick(voices: voices, locale: ie) == nil)
        #expect(BestSystemVoice.pick(voices: [], locale: ie) == nil)
    }

    @Test("language match is case-insensitive; a script tag still finds the region")
    func languageMatching() {
        let voices = [voice("us", "EN-us", .enhanced), voice("gb", "en-GB", .enhanced)]
        #expect(BestSystemVoice.pick(voices: voices, locale: Locale(identifier: "en-Latn-GB")) == "gb")
        #expect(BestSystemVoice.pick(voices: Array(voices.prefix(1)), locale: Locale(identifier: "en-Latn-GB")) == "us")
    }

    @Test("the AVFoundation quality map: default is compact, nothing is lost")
    func qualityMap() {
        #expect(SystemVoices.quality(.default) == .compact)
        #expect(SystemVoices.quality(.enhanced) == .enhanced)
        #expect(SystemVoices.quality(.premium) == .premium)
    }

    @Test("both Built-in providers take a default voice, and both shells set it at launch")
    func wiredEverywhere() throws {
        let av = AVSpeechProvider()
        #expect(av.defaultVoiceIdentifier == nil)
        av.defaultVoiceIdentifier = "x"
        #expect(av.defaultVoiceIdentifier == "x")
        let effectful = EffectfulSpeechProvider(fallback: av)
        effectful.defaultVoiceIdentifier = "y"
        #expect(effectful.defaultVoiceIdentifier == "y")
        #expect(av.defaultVoiceIdentifier == "y", "the plain fallback inherits it")

        let macos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for shell in ["M1K3App/AppEnvironment.swift", "M1K3iOSApp/AppCore.swift"] {
            let source = try String(contentsOf: macos.appendingPathComponent(shell), encoding: .utf8)
            #expect(source.contains("BestSystemVoice.pick("), "\(shell) picks the Built-in voice at launch")
            #expect(source.contains("defaultVoiceIdentifier = "), "\(shell) hands the pick to Built-in")
        }
    }

    @Test("ties break by identifier, so the pick is stable across launches")
    func deterministicTies() {
        let voices = [voice("b", "en-IE", .premium), voice("a", "en-IE", .premium)]
        #expect(BestSystemVoice.pick(voices: voices, locale: ie) == "a")
        #expect(BestSystemVoice.pick(voices: voices.reversed(), locale: ie) == "a")
    }
}
