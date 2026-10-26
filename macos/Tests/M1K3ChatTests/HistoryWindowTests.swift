//
//  HistoryWindowTests.swift
//  M1K3ChatTests
//
//  The minimal chat memory: a tightly capped replay of recent turns rendered
//  into the grounding prompt. Caps are the contract — history replay grows
//  prefill, which fights the TTFT work, so the window must stay small.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-10-17 — the earlier-user trace (#626): user turns the window evicts
//  leave their own words above the replay, within `earlierUserChars`; zero keeps every caller byte-identical.
//

import Foundation
@testable import M1K3Chat
import Testing

struct HistoryWindowTests {
    @Test("no history renders nothing")
    func emptyIsNil() {
        #expect(HistoryWindow.render([]) == nil)
    }

    @Test("turns render in order with role labels")
    func rendersInOrder() {
        let block = HistoryWindow.render([
            ChatTurn(role: .user, text: "What's the weather in Galway?"),
            ChatTurn(role: .assistant, text: "18°C and cloudy."),
        ])
        let text = block ?? ""
        #expect(text.contains("CONVERSATION SO FAR"))
        let userIndex = text.range(of: "USER: What's the weather in Galway?")
        let assistantIndex = text.range(of: "M1K3: 18°C and cloudy.")
        #expect(userIndex != nil)
        #expect(assistantIndex != nil)
        if let userIndex, let assistantIndex {
            #expect(userIndex.lowerBound < assistantIndex.lowerBound)
        }
    }

    @Test("only the most recent turns survive the turn-count ceiling")
    func capsTurnCount() {
        // More turns than the ceiling, each tiny (so the total-char budget can't
        // bite first) — the turn ceiling is what trims. The `END` delimiter keeps
        // "Q1END" from being a substring of "Q10END".
        let n = HistoryWindow.maxTurns + 5
        let turns = (1 ... n).map { ChatTurn(role: .user, text: "Q\($0)END") }
        let text = HistoryWindow.render(turns) ?? ""
        #expect(!text.contains("Q1END")) // oldest dropped
        #expect(text.contains("Q\(n)END")) // newest kept
        #expect(text.components(separatedBy: "USER:").count - 1 == HistoryWindow.maxTurns)
    }

    @Test("the total-char budget keeps newest turns whole and drops the oldest")
    func totalBudgetFillsNewestFirst() {
        // Each turn ~1000 chars (under the per-turn cap, so untruncated). With a
        // ~8K budget only the newest handful fit, even though the turn ceiling
        // would allow all 16 — the budget is the real governor on prefill.
        let big = String(repeating: "x", count: 1000)
        // Bracketed markers so "[1]" can't be a substring of "[11]"/"[16]".
        let turns = (1 ... 16).map { ChatTurn(role: .user, text: "[\($0)]" + big) }
        let text = HistoryWindow.render(turns) ?? ""
        #expect(text.count <= HistoryWindow.maxTotalChars) // header + separators are counted in-budget
        #expect(text.contains("[16]")) // newest survives whole
        #expect(!text.contains("[1]")) // oldest dropped by the budget
    }

    @Test("the most recent turn is never dropped, even against the budget")
    func mostRecentAlwaysKept() {
        // Per-turn cap < total budget, so one turn always fits — guard the invariant.
        let turns = (1 ... 20).map { _ in ChatTurn(role: .assistant, text: String(repeating: "y", count: 2000)) }
        let text = HistoryWindow.render(turns) ?? ""
        #expect(text.contains("M1K3:")) // at least the newest rendered
        #expect(text.contains("…")) // truncated to the per-turn cap
    }

    @Test("a normal-length answer survives intact (no more 400-char mangling)")
    func normalAnswerSurvivesIntact() {
        // ~600 chars: over the OLD 400 cap, under the new per-turn cap → kept whole.
        // This is the "expand on your third point" fix — M1K3's own answer is no
        // longer chopped before the follow-up sees it.
        // ≈623 chars, no trailing space (the per-turn trim would strip it).
        let answer = Array(repeating: "A clear, useful sentence.", count: 24).joined(separator: " ")
        let text = HistoryWindow.render([
            ChatTurn(role: .user, text: "explain it"),
            ChatTurn(role: .assistant, text: answer),
        ]) ?? ""
        #expect(text.contains(answer)) // whole answer present
        #expect(!text.contains("…")) // not truncated
    }

    @Test("turns longer than the per-turn cap truncate with an ellipsis")
    func truncatesLongTurns() {
        let long = String(repeating: "word ", count: 600) // 3000 chars > per-turn cap
        let text = HistoryWindow.render([ChatTurn(role: .assistant, text: long)]) ?? ""
        #expect(text.count < long.count)
        #expect(text.contains("…"))
    }

    @Test("the default budget reproduces the shipped constants byte-for-byte")
    func defaultBudgetMatchesConstants() {
        #expect(HistoryWindow.Budget.default.totalChars == HistoryWindow.maxTotalChars)
        #expect(HistoryWindow.Budget.default.perTurnChars == HistoryWindow.maxCharsPerTurn)
        #expect(HistoryWindow.Budget.default.maxTurns == HistoryWindow.maxTurns)
        let turns = [
            ChatTurn(role: .user, text: "hi"),
            ChatTurn(role: .assistant, text: "hello"),
        ]
        #expect(HistoryWindow.render(turns) == HistoryWindow.render(turns, budget: .default))
    }

    @Test("an injected budget scales the window — wider keeps more, tighter keeps less")
    func injectedBudgetScales() {
        // 30 turns of ~500 chars each. A wide budget keeps far more total than a tight one.
        let turns = (1 ... 30).map { ChatTurn(role: .user, text: "[\($0)]" + String(repeating: "z", count: 500)) }
        let wide = HistoryWindow.render(turns, budget: .init(totalChars: 12000, perTurnChars: 1500, maxTurns: 40)) ?? ""
        let tight = HistoryWindow.render(turns, budget: .init(totalChars: 2000, perTurnChars: 1500, maxTurns: 40)) ?? ""
        #expect(wide.count > tight.count)
        #expect(wide.count <= 12000) // bounded by the injected total, header counted
        #expect(tight.count <= 2000)
        #expect(wide.contains("[30]")) // both keep the newest
        #expect(tight.contains("[30]"))
    }

    @Test("with per-turn headroom for the header the block never exceeds totalChars (the rotating-KV clamp invariant)")
    func renderHonoursHardBound() {
        // HistoryBudgetPolicy's real budgets keep perTurn (≤1500) far below
        // total (thousands), so header + label + one capped line always fit:
        // even the unconditional newest turn can't push the block over the cap.
        // ZERO slack here — header and separators are counted in-budget.
        let turns = (1 ... 20).map { _ in ChatTurn(role: .assistant, text: String(repeating: "q", count: 4000)) }
        let budget = HistoryWindow.Budget(totalChars: 3000, perTurnChars: 2900, maxTurns: 16)
        let text = HistoryWindow.render(turns, budget: budget) ?? ""
        #expect(text.count <= budget.totalChars)
    }

    @Test("whitespace-only turns are skipped")
    func skipsEmptyTurns() {
        #expect(HistoryWindow.render([ChatTurn(role: .assistant, text: "  \n ")]) == nil)
    }

    // MARK: - The earlier-user trace (#626)

    private static let fact = "My sister Rachel is coming to stay, and she's allergic to cats."
    /// Six exchanges; the user's second turn holds the fact a later follow-up asks for.
    private let chat: [ChatTurn] = (1 ... 6).flatMap { n in
        [
            ChatTurn(role: .user, text: n == 2 ? Self.fact : "Question \(n)?"),
            ChatTurn(role: .assistant, text: "Answer \(n). " + String(repeating: "a", count: 300)),
        ]
    }

    private func budget(earlier: Int) -> HistoryWindow.Budget {
        HistoryWindow.Budget(totalChars: 4000, perTurnChars: 1500, maxTurns: 4, earlierUserChars: earlier)
    }

    /// The trace: everything from the header up to the first kept USER line.
    private func trace(_ text: String) -> String {
        let kept = text.range(of: "\nUSER: ")?.lowerBound ?? text.endIndex
        return String(text[..<kept])
    }

    @Test("with no earlier allowance an evicted turn leaves nothing (today's window, byte for byte)")
    func earlierOffIsToday() {
        let off = HistoryWindow.render(chat, budget: budget(earlier: 0)) ?? ""
        let threeField = HistoryWindow.Budget(totalChars: 4000, perTurnChars: 1500, maxTurns: 4)
        let legacy = HistoryWindow.render(chat, budget: threeField) ?? ""
        #expect(off == legacy)
        #expect(!off.contains("Rachel"))
        #expect(!off.contains(HistoryWindow.earlierLabel))
    }

    @Test("evicted user turns open the replay in their own words, oldest first; evicted answers leave nothing")
    func evictedUserTurnsLeaveATrace() {
        let text = HistoryWindow.render(chat, budget: budget(earlier: 1000)) ?? ""
        let earlier = trace(text)
        #expect(text.hasPrefix("CONVERSATION SO FAR"))
        #expect(earlier.contains(HistoryWindow.earlierLabel + "My sister Rachel is coming to stay"))
        #expect(earlier.contains(HistoryWindow.earlierElision))
        // maxTurns 4 keeps exchanges 5 and 6, so exchanges 1–4 are evicted: their user lines are traced in order…
        let order = ["Question 1?", "Rachel", "Question 4?"].map { earlier.range(of: $0)?.lowerBound }
        #expect(order.allSatisfy { $0 != nil })
        let found = order.compactMap(\.self)
        #expect(found == found.sorted())
        // …none of the evicted answers come with them, and the kept window is today's.
        #expect(!earlier.contains("Answer"))
        let legacy = HistoryWindow.render(chat, budget: budget(earlier: 0)) ?? ""
        #expect(text.hasSuffix(String(legacy.dropFirst(HistoryWindow.header.count))))
    }

    @Test("turns cut by the turn ceiling (not just the char budget) reach the trace")
    func turnCeilingEvictionsAreTraced() {
        let long = (1 ... 10).flatMap { n in
            [ChatTurn(role: .user, text: "Fact \(n)."), ChatTurn(role: .assistant, text: "ok")]
        }
        let ceiling = HistoryWindow.Budget(totalChars: 8000, perTurnChars: 1500, maxTurns: 8, earlierUserChars: 600)
        let earlier = trace(HistoryWindow.render(long, budget: ceiling) ?? "")
        #expect(earlier.contains("Fact 1."))
        #expect(earlier.contains("Fact 6."))
        #expect(!earlier.contains("Fact 7."))
    }

    @Test("the trace spends at most earlierUserChars, overhead included, dropping the OLDEST user turns first")
    func earlierHonoursItsBudget() {
        let tight = budget(earlier: 90)
        let text = HistoryWindow.render(chat, budget: tight) ?? ""
        let earlier = trace(text).dropFirst(HistoryWindow.header.count)
        #expect(earlier.count <= tight.earlierUserChars)
        #expect(earlier.contains("Question 4?"))
        #expect(!earlier.contains("Question 1?"))
    }

    @Test("a long evicted user turn is cut to the trace's per-line cap")
    func earlierLinesAreCapped() {
        let ramble = ChatTurn(role: .user, text: String(repeating: "w", count: 2000))
        let long = [ramble, ChatTurn(role: .assistant, text: "ok")] + chat.suffix(4)
        let text = HistoryWindow.render(long, budget: budget(earlier: 3000)) ?? ""
        #expect(text.contains(HistoryWindow.earlierLabel + "www"))
        #expect(!text.contains(String(repeating: "w", count: HistoryWindow.earlierPerLineChars + 1)))
    }

    @Test("nothing evicted, no trace")
    func noEvictionNoTrace() {
        let text = HistoryWindow.render(Array(chat.suffix(4)), budget: budget(earlier: 1000)) ?? ""
        #expect(!text.contains(HistoryWindow.earlierLabel))
        #expect(!text.contains(HistoryWindow.earlierElision))
    }

    @Test("the whole block stays within totalChars + earlierUserChars (the rotating-KV bound, extended)")
    func earlierKeepsTheHardBound() {
        let turns = (1 ... 40).flatMap { _ in
            [
                ChatTurn(role: .user, text: String(repeating: "u", count: 900)),
                ChatTurn(role: .assistant, text: String(repeating: "q", count: 4000)),
            ]
        }
        let bound = HistoryWindow.Budget(totalChars: 3000, perTurnChars: 2900, maxTurns: 16, earlierUserChars: 1000)
        let text = HistoryWindow.render(turns, budget: bound) ?? ""
        #expect(text.contains(HistoryWindow.earlierLabel))
        #expect(text.count <= bound.totalChars + bound.earlierUserChars)
    }

    @Test("reserving room for images keeps the earlier allowance")
    func imagesKeepTheTrace() {
        let budget = budget(earlier: 600).reservingImages(1)
        #expect(budget.earlierUserChars == 600)
        #expect(budget.perTurnChars <= budget.totalChars)
    }

    @Test("only answers evicted: no trace and no lone elision line")
    func onlyAnswersEvictedNoTrace() {
        let turns = [ChatTurn(role: .assistant, text: "An opening line.")] + chat.suffix(4)
        let text = HistoryWindow.render(turns, budget: budget(earlier: 1000)) ?? ""
        #expect(!text.contains(HistoryWindow.earlierElision))
    }

    @Test("an allowance too small for the elision renders today's block")
    func tinyAllowanceIsToday() {
        let tiny = HistoryWindow.render(chat, budget: budget(earlier: 50)) ?? ""
        #expect(tiny == HistoryWindow.render(chat, budget: budget(earlier: 0)))
    }

    @Test("when the newest turn alone overflows totalChars, the trace adds at most earlierUserChars on top")
    func overflowingNewestTurnPlusTrace() {
        let turns = [
            ChatTurn(role: .user, text: Self.fact),
            ChatTurn(role: .assistant, text: "ok"),
            ChatTurn(role: .user, text: String(repeating: "n", count: 900)),
        ]
        let small = HistoryWindow.Budget(totalChars: 200, perTurnChars: 900, maxTurns: 8, earlierUserChars: 300)
        let traced = HistoryWindow.render(turns, budget: small) ?? ""
        let untraced = HistoryWindow.Budget(totalChars: 200, perTurnChars: 900, maxTurns: 8)
        let plain = HistoryWindow.render(turns, budget: untraced) ?? ""
        #expect(traced.contains("Rachel"))
        #expect(traced.count <= plain.count + small.earlierUserChars)
    }

    // MARK: - Block eviction (2026-10-26, design doc §2a)

    private static func tiny(_ n: Int) -> [ChatTurn] {
        (1 ... n).map { ChatTurn(role: $0.isMultiple(of: 2) ? .assistant : .user, text: "T\($0)END") }
    }

    private static func firstKept(_ text: String) -> String? {
        text.components(separatedBy: "\n").dropFirst().first
    }

    @Test("a block of one is today's window, byte for byte")
    func blockOfOneIsIdentity() {
        let turns = Self.tiny(HistoryWindow.maxTurns + 7)
        let block1 = HistoryWindow.Budget(
            totalChars: 8000, perTurnChars: 1500, maxTurns: HistoryWindow.maxTurns, evictionBlockTurns: 1
        )
        #expect(HistoryWindow.render(turns, budget: block1) == HistoryWindow.render(turns))
        #expect(HistoryWindow.Budget.default.evictionBlockTurns == 1)
    }

    @Test("the window's start is a multiple of the block, so consecutive renders share it")
    func startSnapsToTheBlock() {
        // 16 kept of n: today's start is n − 16, moving one turn per turn. With a block of 6 the
        // start rounds UP to the next multiple of 6 (dropping up to five more of the oldest), so
        // n = 17…22 all start at turn 7 and n = 23…28 at turn 13: a prefix the KV cache can keep.
        let budget = HistoryWindow.Budget(totalChars: 8000, perTurnChars: 1500, maxTurns: 16, evictionBlockTurns: 6)
        for n in 17 ... 22 {
            let text = HistoryWindow.render(Self.tiny(n), budget: budget) ?? ""
            #expect(Self.firstKept(text) == "USER: T7END", "n=\(n)")
            #expect(text.contains("T\(n)END"))
            #expect(!text.contains("T6END"))
        }
        for n in 23 ... 28 {
            let text = HistoryWindow.render(Self.tiny(n), budget: budget) ?? ""
            #expect(Self.firstKept(text) == "USER: T13END", "n=\(n)")
        }
        // Never more than the ceiling: the last render of a block keeps exactly maxTurns.
        let full = HistoryWindow.render(Self.tiny(22), budget: budget) ?? ""
        #expect(full.components(separatedBy: "\n").count - 1 == 16)
    }

    @Test("the char budget's cut snaps to the block too")
    func charBudgetCutSnaps() {
        // Each line is "USER: xxxxxxxxxxEND" ≈ 19 chars; ~200 chars of budget keeps about eight.
        let turns = (1 ... 30).map { ChatTurn(role: .user, text: "x\(String(repeating: "x", count: 9))END\($0)") }
        let plain = HistoryWindow.Budget(totalChars: 220, perTurnChars: 100, maxTurns: 40)
        let blocked = HistoryWindow.Budget(totalChars: 220, perTurnChars: 100, maxTurns: 40, evictionBlockTurns: 6)
        let p = HistoryWindow.render(turns, budget: plain) ?? ""
        let b = HistoryWindow.render(turns, budget: blocked) ?? ""
        let pKept = p.components(separatedBy: "\n").count - 1
        let bKept = b.components(separatedBy: "\n").count - 1
        #expect(bKept <= pKept)
        #expect((30 - bKept).isMultiple(of: 6))
        #expect(b.count <= blocked.totalChars + 0) // the snap only ever keeps fewer: the bound holds
        #expect(b.hasSuffix("END30"))
    }

    @Test("the newest turn always survives the snap")
    func newestSurvivesTheSnap() {
        // Seven turns, a two-turn ceiling: today's start is 5; snapped to 6 keeps just T7. A snap
        // that would pass the newest turn clamps to it.
        let budget = HistoryWindow.Budget(totalChars: 8000, perTurnChars: 1500, maxTurns: 2, evictionBlockTurns: 6)
        let text = HistoryWindow.render(Self.tiny(7), budget: budget) ?? ""
        #expect(text.components(separatedBy: "\n").count - 1 == 1)
        #expect(text.contains("T7END"))
        let one = HistoryWindow.render(Self.tiny(1), budget: budget) ?? ""
        #expect(one.contains("T1END"))
        let eight = HistoryWindow.Budget(totalChars: 8000, perTurnChars: 1500, maxTurns: 1, evictionBlockTurns: 8)
        #expect((HistoryWindow.render(Self.tiny(9), budget: eight) ?? "").contains("T9END"))
    }

    @Test("turns the snap drops are evicted turns: their user lines join the earlier-user trace")
    func snappedTurnsAreTraced() {
        let budget = HistoryWindow.Budget(
            totalChars: 8000, perTurnChars: 1500, maxTurns: 16, evictionBlockTurns: 6, earlierUserChars: 400
        )
        let text = HistoryWindow.render(Self.tiny(18), budget: budget) ?? ""
        // Start snapped from 2 to 6: T3 and T5 (user turns) were dropped by the snap, not the ceiling.
        #expect(text.contains("USER (earlier): T5END"))
        #expect(text.contains("USER (earlier): T3END"))
        #expect(text.contains("USER (earlier): T1END"))
        #expect(!text.contains("USER: T5END"))
    }
}
