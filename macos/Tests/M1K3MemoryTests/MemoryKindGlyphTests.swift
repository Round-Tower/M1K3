//
//  MemoryKindGlyphTests.swift
//  M1K3MemoryTests
//
//  Pins the per-kind symbol the Memories list shows instead of one brain for
//  every row (launch snag list, 2026-09-12): a profile fact, a preference, a
//  decision, an episode and a note each read as what they are at a glance.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699: `style` wears its own glyph, apart from every
//  catalogued kind and the brain fallback. Confidence 0.85.

import M1K3Memory
import Testing

struct MemoryKindGlyphTests {
    @Test("every catalogued kind has its own symbol")
    func cataloguedKindsAreDistinct() {
        let symbols = MemoryKind.catalogued.map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { !$0.isEmpty })
    }

    @Test("the named kinds map to their glyphs")
    func namedKinds() {
        #expect(MemoryKind.profile.symbolName == "person.crop.circle")
        #expect(MemoryKind.preference.symbolName == "heart")
        #expect(MemoryKind.decision.symbolName == "checkmark.seal")
        #expect(MemoryKind.episode.symbolName == "clock")
        #expect(MemoryKind.note.symbolName == "note.text")
    }

    @Test("style (#699) wears its own glyph, apart from every catalogued kind and the brain")
    func styleHasItsOwnGlyph() {
        #expect(MemoryKind.style.symbolName == "text.bubble")
        #expect(!MemoryKind.catalogued.map(\.symbolName).contains(MemoryKind.style.symbolName))
        #expect(MemoryKind.style.symbolName != "brain")
    }

    @Test("an uncatalogued kind falls back to the brain")
    func unknownFallsBack() {
        #expect(MemoryKind(rawValue: "whatever").symbolName == "brain")
    }
}
