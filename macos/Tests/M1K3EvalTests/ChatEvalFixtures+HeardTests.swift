//
//  ChatEvalFixtures+HeardTests.swift
//  M1K3EvalTests
//
//  Pins the heard kind's shape (#852): a garble's fact is never in its own prompt (it has to be
//  recovered, not read), each garble names its swap, the guards are there, and the kind sits last.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-16, Confidence 0.85. Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-11-19 — the language kind now sits last; heard is pinned just before it.
//

@testable import M1K3Eval
import Testing

struct ChatEvalFixturesHeardTests {
    @Test("the registry hands the heard kind exactly its own fixtures")
    func registered() {
        #expect(ChatEvalFixtures.fixtures(for: .heard).count == ChatEvalFixtures.heard.count)
    }

    @Test("a garble's fact is not in its prompt: the brain has to read past the swap to say it")
    func factsAreRecovered() {
        for fixture in ChatEvalFixtures.heard where !fixture.id.hasPrefix("heard-guard") {
            let prompt = fixture.prompt.lowercased()
            for fact in fixture.expectation.mustContainAny + fixture.expectation.mustContainAll {
                #expect(!prompt.contains(fact.lowercased()), "\(fixture.id): \(fact) is in the prompt")
            }
        }
    }

    @Test("a garble names its swap as a must-not, so parroting it back fails")
    func swapsAreMustNots() {
        for fixture in ChatEvalFixtures.heard where !fixture.id.hasPrefix("heard-guard") {
            let swaps = fixture.expectation.mustNotContain.filter { !ChatEvalFixtures.leakMarkers.contains($0) }
            #expect(!swaps.isEmpty, "\(fixture.id) names no swap")
            for swap in swaps where !fixture.id.hasPrefix("heard-idiom") {
                #expect(fixture.prompt.lowercased().contains(swap), "\(fixture.id): \(swap) isn't the prompt's swap")
            }
        }
    }

    @Test("the kind sits just before language (2026-11-19), so no earlier run's order moves")
    func heardIsBeforeLanguage() throws {
        let kinds = TaskKind.allCases
        let heard = try #require(kinds.firstIndex(of: .heard))
        #expect(kinds[kinds.index(after: heard)] == .language)
        let lastHeard = try #require(ChatEvalFixtures.all.lastIndex { $0.kind == .heard })
        #expect(ChatEvalFixtures.all[lastHeard...].dropFirst().allSatisfy { $0.kind == .language })
    }

    @Test("at least five guards: a real odd word, a clean turn and a tool turn stay as they are")
    func guards() {
        let guards = ChatEvalFixtures.heard.filter { $0.id.hasPrefix("heard-guard") }
        #expect(guards.count >= 5)
        #expect(guards.contains { $0.expectation.mustCallTool != nil })
        #expect(guards.contains { $0.prompt.lowercased().contains("curry") })
    }
}
