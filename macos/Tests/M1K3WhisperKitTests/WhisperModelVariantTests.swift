//
//  WhisperModelVariantTests.swift
//  M1K3WhisperKitTests
//
//  Pins the user-selectable WhisperKit accuracy tier: the stored-preference
//  parsing (with a safe fallback) and the small.en default that ships sharper
//  transcripts out of the box.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.9, Prior: Unknown

@testable import M1K3WhisperKit
import Testing

struct WhisperModelVariantTests {
    @Test("model id maps to the WhisperKit variant string")
    func modelID() {
        #expect(WhisperModelVariant.tiny.modelID == "tiny.en")
        #expect(WhisperModelVariant.base.modelID == "base.en")
        #expect(WhisperModelVariant.small.modelID == "small.en")
    }

    @Test("the shipped default is small.en — accuracy-first within a sane download")
    func defaultIsSmall() {
        #expect(WhisperModelVariant.defaultVariant == .small)
    }

    @Test("stored preference parses, unknown/missing falls back to the default")
    func fromStored() {
        #expect(WhisperModelVariant.from(stored: "tiny.en") == .tiny)
        #expect(WhisperModelVariant.from(stored: "base.en") == .base) // the existing-user value
        #expect(WhisperModelVariant.from(stored: "small.en") == .small)
        #expect(WhisperModelVariant.from(stored: nil) == .defaultVariant)
        #expect(WhisperModelVariant.from(stored: "garbage") == .defaultVariant)
    }

    @Test("an explicit pick always wins, even if another model is installed")
    func resolveExplicitWins() {
        let variant = WhisperModelVariant.resolve(stored: "tiny.en", isInstalled: { $0 == .small })
        #expect(variant == .tiny)
    }

    @Test("with no pick, an already-installed model is kept over the default")
    func resolveKeepsInstalled() {
        // A returning base.en user (no explicit pick) keeps base, not a small re-download.
        #expect(WhisperModelVariant.resolve(stored: nil, isInstalled: { $0 == .base }) == .base)
    }

    @Test("with no pick and several installed, the most accurate installed wins")
    func resolvePrefersBestInstalled() {
        let variant = WhisperModelVariant.resolve(stored: nil, isInstalled: { $0 == .tiny || $0 == .base })
        #expect(variant == .base) // base > tiny
    }

    @Test("with no pick and nothing installed, the shipped default wins")
    func resolveFallsBackToDefault() {
        #expect(WhisperModelVariant.resolve(stored: nil, isInstalled: { _ in false }) == .small)
    }

    @Test("the picker lists tiny → base → small in ascending accuracy")
    func ordering() {
        #expect(WhisperModelVariant.allCases == [.tiny, .base, .small])
    }

    @Test("approxBytes matches the MB figure in the picker's size hint (the downloads list quotes it)")
    func approxBytesMatchesHint() {
        for variant in WhisperModelVariant.allCases {
            let hintMB = variant.sizeHint.split(separator: " ").first
                .flatMap { Int($0.drop { $0 == "~" }) }
            #expect(variant.approxBytes == Int64(hintMB ?? -1) * 1_000_000, "\(variant)")
        }
    }

    @Test("each tier has a non-empty label and size hint for the picker")
    func labels() {
        for variant in WhisperModelVariant.allCases {
            #expect(!variant.displayName.isEmpty)
            #expect(!variant.sizeHint.isEmpty)
        }
    }
}
