//
//  InferencePhosphorTests.swift
//  M1K3AvatarTests
//
//  The load-bearing test is the PRIVACY one (visitorLinesAreGlyphsOnly): a
//  visiting agent's content can never reach the rain, by the type's shape.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.9, Prior: Unknown
//

import Foundation
@testable import M1K3Avatar
import Testing

private let t0 = Date(timeIntervalSince1970: 1_000_000)

struct InferencePhosphorTests {
    @Test("own output is shown verbatim — reasoning text passes through, whitespace-collapsed")
    func ownVerbatim() {
        var rain = InferencePhosphor()
        rain.ingestOwn("the   user\nis  in  Ardmore", source: .thinking, at: t0)
        #expect(rain.lines.count == 1)
        #expect(rain.lines[0].text == "the user is in Ardmore")
        #expect(rain.lines[0].source == .thinking)
    }

    @Test("★ a visitor line is DERIVED GLYPHS — no content can reach it, by construction")
    func visitorLinesAreGlyphsOnly() {
        var rain = InferencePhosphor()
        // There is NO text parameter on ingestVisitor — a seed and a length.
        rain.ingestVisitor(seed: 0, length: 12, at: t0)
        rain.ingestVisitor(seed: 0xDEAD_BEEF, length: 8, at: t0.addingTimeInterval(1))
        let alphabet = Set(InferencePhosphor.glyphAlphabet)
        for line in rain.lines {
            #expect(line.source == .visitor)
            // Every character is a derived glyph — never a letter or digit
            // that could spell a visitor's prompt.
            #expect(line.text.allSatisfy { alphabet.contains($0) })
            #expect(!line.text.contains { $0.isLetter || $0.isNumber })
        }
    }

    @Test("visitor glyph derivation is deterministic (SelfTest/CI reproducible)")
    func visitorDeterministic() {
        var a = InferencePhosphor()
        var b = InferencePhosphor()
        a.ingestVisitor(seed: 42, length: 10, at: t0)
        b.ingestVisitor(seed: 42, length: 10, at: t0)
        #expect(a.lines[0].text == b.lines[0].text)
        // A different seed gives a different rain (not a constant).
        var c = InferencePhosphor()
        c.ingestVisitor(seed: 43, length: 10, at: t0)
        #expect(c.lines[0].text != a.lines[0].text)
    }

    @Test("a .visitor source cannot smuggle text in through ingestOwn")
    func ingestOwnRejectsVisitorSource() {
        var rain = InferencePhosphor()
        rain.ingestOwn("secret prompt from a visitor", source: .visitor, at: t0)
        #expect(rain.lines.isEmpty)
    }

    @Test("blank own input is ignored; a run identical to the head doesn't stack")
    func ignoresBlankAndDuplicates() {
        var rain = InferencePhosphor()
        rain.ingestOwn("   ", source: .answer, at: t0)
        rain.ingestOwn("", source: .answer, at: t0)
        #expect(rain.lines.isEmpty)
        rain.ingestOwn("hello", source: .answer, at: t0)
        rain.ingestOwn("hello", source: .answer, at: t0.addingTimeInterval(0.1))
        #expect(rain.lines.count == 1)
    }

    @Test("a long fragment is capped to a legible length")
    func fragmentCapped() {
        var rain = InferencePhosphor(fragmentCap: 10)
        rain.ingestOwn("abcdefghijklmnopqrstuvwxyz", source: .thinking, at: t0)
        #expect(rain.lines[0].text.count == 10)
    }

    @Test("the rain caps at maxLines, dropping the oldest")
    func capsAtMaxLines() {
        var rain = InferencePhosphor(maxLines: 3)
        for i in 0 ..< 6 {
            rain.ingestOwn("line \(i)", source: .thinking, at: t0.addingTimeInterval(Double(i)))
        }
        #expect(rain.lines.count == 3)
        #expect(rain.lines.map(\.text) == ["line 3", "line 4", "line 5"])
    }

    @Test("opacity ramps in, holds, then fades to zero across the line's life")
    func opacityCurve() {
        let rain = InferencePhosphor(lineTTL: 10, fadeIn: 1)
        let line = PhosphorLine(id: 0, text: "x", source: .answer, bornAt: t0)
        #expect(rain.opacity(for: line, at: t0) == 0) // birth
        #expect(rain.opacity(for: line, at: t0.addingTimeInterval(0.5)) == 0.5) // mid-ramp
        #expect(rain.opacity(for: line, at: t0.addingTimeInterval(3)) == 1) // hold
        #expect(rain.opacity(for: line, at: t0.addingTimeInterval(9.9)) < 0.1) // tail
        #expect(rain.opacity(for: line, at: t0.addingTimeInterval(10)) == 0) // dead
    }

    @Test("prune drops expired lines; active reflects the live set without mutating")
    func pruneAndActive() {
        var rain = InferencePhosphor(lineTTL: 5)
        rain.ingestOwn("old", source: .thinking, at: t0)
        rain.ingestOwn("new", source: .thinking, at: t0.addingTimeInterval(4))
        let now = t0.addingTimeInterval(6) // "old" expired, "new" alive
        #expect(rain.active(at: now).map(\.text) == ["new"])
        #expect(rain.lines.count == 2) // active() is non-mutating
        rain.prune(at: now)
        #expect(rain.lines.map(\.text) == ["new"])
    }

    @Test("rise climbs from 0 at birth to the full height at TTL")
    func riseCurve() {
        let rain = InferencePhosphor(lineTTL: 4)
        let line = PhosphorLine(id: 0, text: "x", source: .answer, bornAt: t0)
        #expect(rain.rise(for: line, at: t0, riseHeight: 100) == 0)
        #expect(rain.rise(for: line, at: t0.addingTimeInterval(2), riseHeight: 100) == 50)
        #expect(rain.rise(for: line, at: t0.addingTimeInterval(4), riseHeight: 100) == 100)
    }
}
