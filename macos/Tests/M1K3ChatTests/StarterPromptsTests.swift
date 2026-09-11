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
        #expect(picks.allSatisfy { StarterPrompts.phonePool.contains($0) })
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

    @Test("the phone's pool still carries the door chips — moving one to the Mac's door took nothing off the phone")
    func phoneKeepsTheDoorChips() {
        var seen = Set<String>()
        for seed in UInt64(1) ... 60 {
            var rng = FixedRNG(state: seed)
            seen.formUnion(StarterPrompts.pick(memoryTitles: [], using: &rng))
        }
        #expect(seen.contains("What do you remember about me?"))
        #expect(StarterPrompts.phonePool.count == StarterPrompts.pool.count + StarterPrompts.doorPool.count)
    }

    @Test("recent memories: at most two memory chips, the rest from the pool, still three")
    func weavesMemories() {
        var rng = FixedRNG(state: 7)
        let picks = StarterPrompts.pick(
            memoryTitles: ["Ardmore cliff walk", "The Round Tower", "Kev's coffee order"], using: &rng
        )
        #expect(picks.count == 3)
        let memoryChips = picks.filter { !StarterPrompts.phonePool.contains($0) }
        #expect(memoryChips.count == 2)
        #expect(memoryChips.allSatisfy { $0.contains("Ardmore") || $0.contains("Round Tower") })
    }

    @Test("blank or whitespace titles are skipped")
    func skipsBlankTitles() {
        var rng = FixedRNG(state: 3)
        let picks = StarterPrompts.pick(memoryTitles: ["  ", ""], using: &rng)
        #expect(picks.allSatisfy { StarterPrompts.phonePool.contains($0) })
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
        let chip = picks.first { !StarterPrompts.phonePool.contains($0) }
        #expect(chip != nil)
        #expect((chip?.count ?? 0) <= StarterPrompts.maxChipLength)
    }
}

// MARK: - The context-aware rule (Mac blank canvas, 2026-09-11)

private let fullContext = StarterPrompts.Context(
    memoryTitles: ["Kev prefers dark mode", "Jazz festival is 23–26 October"],
    conversationTitles: ["Cork Jazz Festival 2026 Lineup", "M1K3 on the machine — quiet code"],
    openTodoCount: 3, overdueTodoCount: 1,
    latestPulseAge: 3 * 3600,
    visitorCallsToday: 14, visitorNames: ["Claude Code"],
    hour: 23
)

struct StarterPromptsContextTests {
    private func pick(_ context: StarterPrompts.Context, count: Int = 4, seed: UInt64 = 1) -> [String] {
        var rng = FixedRNG(state: seed)
        return StarterPrompts.pick(context: context, count: count, using: &rng)
    }

    @Test("four chips: exactly one door, at most two from context, at least one from the pool, all one line")
    func shape() {
        for seed in UInt64(1) ... 40 {
            let picks = pick(fullContext, seed: seed)
            #expect(picks.count == 4)
            #expect(Set(picks).count == 4)
            #expect(picks.count(where: { StarterPrompts.doorPool.contains($0) }) == 1)
            #expect(picks.count(where: { StarterPrompts.pool.contains($0) }) >= 1)
            let context = picks.filter { !StarterPrompts.doorPool.contains($0) && !StarterPrompts.pool.contains($0) }
            #expect(context.count <= StarterPrompts.maxContextChips)
            #expect(picks.allSatisfy { $0.count <= StarterPrompts.maxChipLength })
        }
    }

    @Test("the draw varies across seeds — different chips, not just different orders")
    func varies() {
        var seen = Set<String>()
        for seed in UInt64(1) ... 40 {
            seen.formUnion(pick(fullContext, seed: seed))
        }
        #expect(seen.count > 8)
    }

    @Test("an empty context: one door + pool only")
    func emptyContext() {
        let picks = pick(.empty)
        #expect(picks.count == 4)
        #expect(picks.count(where: { StarterPrompts.doorPool.contains($0) }) == 1)
        #expect(picks.count(where: { StarterPrompts.pool.contains($0) }) == 3)
    }

    @Test("every context source yields its chip, and none without its fact")
    func candidates() {
        let all = StarterPrompts.candidates(for: fullContext)
        let texts = all.map(\.text)
        #expect(texts.contains("Remind me about Kev prefers dark mode"))
        #expect(texts.contains("Pick up “Cork Jazz Festival 2026 Lineup”?"))
        #expect(texts.contains("What's overdue?"))
        #expect(texts.contains("What did you notice while I was away?"))
        #expect(texts.contains("What did Claude Code want today?"))
        #expect(texts.contains("What have we been up to lately?"))
        #expect(texts.contains("It's late. One calm thought?"))
        #expect(all.allSatisfy { $0.text.count <= StarterPrompts.maxChipLength })
        // At most two per source (memories, conversations), one for the rest.
        for source in StarterPrompts.Source.allCases {
            #expect(all.count(where: { $0.source == source }) <= source.cap, "\(source)")
        }
        let none = StarterPrompts.candidates(for: .empty)
        #expect(none.isEmpty)
    }

    @Test("todos without an overdue one ask about the list; visitors without a name ask generally; a morning hour")
    func variants() {
        var context = StarterPrompts.Context.empty
        context.openTodoCount = 2
        context.visitorCallsToday = 3
        context.hour = 8
        let texts = StarterPrompts.candidates(for: context).map(\.text)
        #expect(texts.contains("What's on my list?"))
        #expect(texts.contains("What have the visitors been up to?"))
        #expect(texts.contains("Morning. Two-minute plan for today?"))
        #expect(!texts.contains("What's overdue?"))
        // Visitor traffic alone is activity worth reviewing.
        #expect(texts.contains("What have we been up to lately?"))
    }

    @Test("blank-only titles earn no activity chip — the gate trims like the candidates do")
    func blankTitlesAreNotActivity() {
        var context = StarterPrompts.Context.empty
        context.memoryTitles = ["  ", "\n"]
        context.conversationTitles = ["\t", ""]
        #expect(StarterPrompts.candidates(for: context).isEmpty)
        // A real title alongside the blanks still counts.
        context.conversationTitles = ["\t", "Ardmore"]
        let texts = StarterPrompts.candidates(for: context).map(\.text)
        #expect(texts.contains("What have we been up to lately?"))
    }

    @Test("a stale pulse and a mid-day hour add nothing")
    func gates() {
        var context = StarterPrompts.Context.empty
        context.latestPulseAge = 3 * 24 * 3600
        context.hour = 14
        #expect(StarterPrompts.candidates(for: context).isEmpty)
    }

    @Test("long conversation titles and visitor names are trimmed so the chip stays one line")
    func trims() {
        var context = StarterPrompts.Context.empty
        context.conversationTitles = [String(repeating: "word ", count: 20)]
        context.visitorCallsToday = 1
        context.visitorNames = [String(repeating: "n", count: 60)]
        let texts = StarterPrompts.candidates(for: context).map(\.text)
        #expect(texts.allSatisfy { $0.count <= StarterPrompts.maxChipLength })
        #expect(texts.contains { $0.hasPrefix("Pick up “word") && $0.hasSuffix("…”?") })
        #expect(texts.contains { $0.hasPrefix("What did nnn") && $0.hasSuffix("… want today?") })
    }

    @Test("smaller counts: one chip is the door alone, two is door + one, three is door + one context + one pool")
    func smallerCounts() {
        for seed in UInt64(1) ... 20 {
            let one = pick(fullContext, count: 1, seed: seed)
            #expect(one.count == 1)
            #expect(StarterPrompts.doorPool.contains(one[0]))
            let two = pick(fullContext, count: 2, seed: seed)
            #expect(two.count == 2)
            #expect(two.count(where: { StarterPrompts.doorPool.contains($0) }) == 1)
            let three = pick(fullContext, count: 3, seed: seed)
            #expect(three.count == 3)
            #expect(three.count(where: { StarterPrompts.doorPool.contains($0) }) == 1)
            #expect(three.count(where: { StarterPrompts.pool.contains($0) }) == 1)
        }
        #expect(pick(fullContext, count: 0).isEmpty)
    }

    @Test("a control character or newline inside a visitor name or title folds to a space")
    func foldsUntrustedText() {
        var context = StarterPrompts.Context.empty
        context.visitorCallsToday = 1
        context.visitorNames = ["Cur\nsor\u{0000}X"]
        context.conversationTitles = ["Line\rbreak", "Crlf\r\nbreak"]
        let texts = StarterPrompts.candidates(for: context).map(\.text)
        #expect(texts.contains("What did Cur sor X want today?"))
        #expect(texts.contains("Pick up “Line break”?"))
        // A CRLF (two scalars) folds to ONE space, not two.
        #expect(texts.contains("Pick up “Crlf break”?"))
        #expect(texts.allSatisfy { !$0.contains("\n") && !$0.contains("\r") })
    }

    @Test("the fixed strings never collide: door, pool and every context template are disjoint")
    func fixedStringsAreDisjoint() {
        let fixed = StarterPrompts.doorPool + StarterPrompts.pool
        #expect(Set(fixed).count == fixed.count)
        var context = fullContext
        context.hour = 8
        let templates = StarterPrompts.candidates(for: context).map(\.text)
        #expect(Set(templates).isDisjoint(with: fixed))
    }

    @Test("a conversation title that matches a memory chip is not printed twice")
    func dedupes() {
        var context = StarterPrompts.Context.empty
        context.memoryTitles = ["Ardmore", "Ardmore"]
        context.conversationTitles = ["Ardmore", "Ardmore"]
        for seed in UInt64(1) ... 10 {
            let picks = pick(context, seed: seed)
            #expect(Set(picks).count == picks.count)
        }
    }
}
