//
//  StarterPromptsTests.swift
//  M1K3ChatTests
//
//  The blank-canvas chips: shuffled from a pool, with recent memories woven in
//  (QA pass, 2026-09-05, item 10). Deterministic under a seeded generator.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.9. Prior: none (new file).
//

@testable import M1K3Chat
import Testing

private struct FixedRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

struct StarterPromptsTests {
    @Test("no memories: three distinct prompts from the pool")
    func poolOnly() {
        var rng = FixedRNG(state: 1)
        let picks = StarterPrompts.pick(memoryTitles: [], using: &rng)
        #expect(picks.count == 3)
        #expect(Set(picks).count == 3)
        #expect(picks.allSatisfy { StarterPrompts.pool.contains($0) })
    }

    @Test("two different seeds give different orders — the chips are not fixed")
    func varies() {
        var a = FixedRNG(state: 1)
        var b = FixedRNG(state: 99)
        let first = StarterPrompts.pick(memoryTitles: [], using: &a)
        var seen = Set([first])
        for seed in 2 ... 40 {
            b = FixedRNG(state: UInt64(seed))
            seen.insert(StarterPrompts.pick(memoryTitles: [], using: &b))
        }
        #expect(seen.count > 1)
    }

    @Test("recent memories: at most two memory chips, the rest from the pool, still three")
    func weavesMemories() {
        var rng = FixedRNG(state: 7)
        let picks = StarterPrompts.pick(
            memoryTitles: ["Ardmore cliff walk", "The Round Tower", "Kev's coffee order"], using: &rng
        )
        #expect(picks.count == 3)
        let memoryChips = picks.filter { !StarterPrompts.pool.contains($0) }
        #expect(memoryChips.count == 2)
        #expect(memoryChips.allSatisfy { $0.contains("Ardmore") || $0.contains("Round Tower") })
    }

    @Test("blank or whitespace titles are skipped")
    func skipsBlankTitles() {
        var rng = FixedRNG(state: 3)
        let picks = StarterPrompts.pick(memoryTitles: ["  ", ""], using: &rng)
        #expect(picks.allSatisfy { StarterPrompts.pool.contains($0) })
    }

    @Test("duplicate titles — and long titles that collide once trimmed — yield one chip each")
    func dedupesMemoryChips() {
        var rng = FixedRNG(state: 5)
        let long = String(repeating: "same start ", count: 8)
        let picks = StarterPrompts.pick(memoryTitles: ["Ardmore", "Ardmore", long + "A", long + "B"], using: &rng)
        #expect(picks.count == 3)
        #expect(Set(picks).count == 3)
    }

    @Test("a long title is trimmed so the chip stays one line")
    func trimsLongTitle() {
        var rng = FixedRNG(state: 3)
        let long = String(repeating: "word ", count: 30)
        let picks = StarterPrompts.pick(memoryTitles: [long], using: &rng)
        let chip = picks.first { !StarterPrompts.pool.contains($0) }
        #expect(chip != nil)
        #expect((chip?.count ?? 0) <= StarterPrompts.maxChipLength)
    }
}
