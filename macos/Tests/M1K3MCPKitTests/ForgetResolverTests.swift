//
//  ForgetResolverTests.swift
//  M1K3MCPKitTests
//
//  The forget decision is irreversible, so its bar is pinned hard: the top hit
//  must clear the forget floor (above recall's threshold) on its own, a near-miss
//  surfaces the closest instead of deleting, and an FTS-only (no-cosine) hit is
//  never confident.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.95 (pure decision over
//  constructed hits). Prior: Unknown.
//

@testable import M1K3MCPKit
import M1K3Memory
import Testing

struct ForgetResolverTests {
    private func hit(_ text: String, similarity: Float?) -> MemoryHit {
        MemoryHit(memory: Memory(kind: .note, text: text, source: "test"), similarity: similarity)
    }

    @Test("a confident top hit (≥ floor) resolves to forget")
    func confidentForgets() {
        let hits = [hit("Kev's sister is Aoife.", similarity: 0.82)]
        guard case let .forget(memory) = ForgetResolver.resolve(hits: hits, query: "Kev's sister is Aoife.") else {
            Issue.record("expected .forget"); return
        }
        #expect(memory.text == "Kev's sister is Aoife.")
    }

    @Test("a hit exactly at the floor (0.6) resolves to forget (>= is inclusive)")
    func atFloorForgets() {
        let hits = [hit("Kev's team is Round Tower.", similarity: ForgetResolver.floor)]
        guard case .forget = ForgetResolver.resolve(
            hits: hits, query: "Kev's team is Round Tower."
        ) else {
            Issue.record("expected .forget at the floor"); return
        }
    }

    @Test("a near-miss (below floor) keeps the fact and returns it as closest")
    func nearMissKeeps() {
        let hits = [hit("Kev likes tea.", similarity: 0.55)] // cleared recall (0.51), not forget (0.6)
        guard case let .notConfident(closest) = ForgetResolver.resolve(
            hits: hits, query: "Kev likes tea."
        ) else {
            Issue.record("expected .notConfident"); return
        }
        #expect(closest?.text == "Kev likes tea.")
    }

    @Test("a rock-bottom top hit is NOT offered as a near-miss — no random-fact suggestions")
    func rockBottomHitNotSuggested() {
        // With the 07-09 threshold-0 candidate search, recall always returns
        // SOMETHING from a populated store. A closest at cosine 0.12 is a
        // random fact, and inviting a word-for-word repeat of it is a consent
        // hazard — below the suggestion floor the honest answer is "nothing
        // matching", exactly as if the store were empty.
        let hits = [hit("Kev drinks his coffee black.", similarity: 0.12)]
        #expect(
            ForgetResolver.resolve(hits: hits, query: "Kev drinks his coffee black.")
                == .notConfident(closest: nil)
        )
    }

    @Test("a hit exactly at the suggestion floor is still offered as closest (>= is inclusive)")
    func suggestionFloorInclusive() {
        let hits = [hit("Kev drinks his coffee black.", similarity: ForgetResolver.suggestionFloor)]
        #expect(
            ForgetResolver.resolve(hits: hits, query: "Kev drinks his coffee black.")
                == .notConfident(closest: hits[0].memory)
        )
    }

    @Test("no hits at all resolves to notConfident with no closest")
    func nothingMatched() {
        #expect(ForgetResolver.resolve(hits: [], query: "anything at all") == .notConfident(closest: nil))
    }

    @Test("an FTS-only hit (no cosine) is never confident enough to delete")
    func ftsOnlyIsNeverConfident() {
        let hits = [hit("Kev's sister is Aoife.", similarity: nil)]
        guard case let .notConfident(closest) = ForgetResolver.resolve(
            hits: hits, query: "Kev's sister is Aoife."
        ) else {
            Issue.record("expected .notConfident"); return
        }
        #expect(closest?.text == "Kev's sister is Aoife.")
    }

    @Test("the top hit is the one judged (best-first ordering is honoured)")
    func judgesTheTopHit() {
        let hits = [
            hit("Kev's sister is Aoife.", similarity: 0.9),
            hit("Aoife's birthday is in March.", similarity: 0.7),
        ]
        guard case let .forget(memory) = ForgetResolver.resolve(
            hits: hits, query: "Kev's sister is Aoife."
        ) else {
            Issue.record("expected .forget"); return
        }
        #expect(memory.text == "Kev's sister is Aoife.")
    }

    // MARK: - Named-fact requirement (the 2026-08-09 live incident)

    /// LIVE INCIDENT, 2026-08-09. `forget_memory` was handed the exact text of a
    /// stored fact; recall did not return that fact AT ALL; and the resolver
    /// hard-deleted rank-1 — a different, TRUE fact — because it cleared 0.6.
    ///
    /// Short generic user-facts all sit at 0.55–0.70 against one another, so in
    /// this store *something* always clears the bar. The floor was calibrated on
    /// the header's assumption that "a verbatim repeat is cosine ≈ 1.0" — true
    /// only if the target is in the candidate set, and with `limit: 3` it often
    /// is not. The bar was measuring confidence in the wrong thing: how close
    /// rank-1 is, never whether rank-1 is the fact the caller named.
    ///
    /// Deletion is irreversible and this tool is reachable by any MCP client.
    /// So: no exact text, no delete. Refusing costs a second round-trip;
    /// guessing costs a true fact, permanently.
    @Test("a fact the caller did NOT name is never deleted, however close it ranks")
    func neverDeletesAnUnnamedFact() {
        let hits = [
            hit("The user is associated with Brightbeam AI Limited.", similarity: 0.65),
            hit("The user is comfortable with AI assistance for various tasks.", similarity: 0.61),
        ]
        #expect(
            ForgetResolver.resolve(hits: hits, query: "The user is a curious AI.")
                == .notConfident(closest: hits[0].memory)
        )
    }

    @Test("an exactly-named fact wins over a higher-ranked neighbour")
    func exactMatchBeatsRank() {
        let hits = [
            hit("The user's name is not disclosed.", similarity: 0.71),
            hit("The user's name is M1K3.", similarity: 0.68),
        ]
        guard case let .forget(memory) = ForgetResolver.resolve(
            hits: hits, query: "The user's name is M1K3."
        ) else {
            Issue.record("expected .forget"); return
        }
        #expect(memory.text == "The user's name is M1K3.")
    }

    @Test("naming a fact tolerates case, spacing and a trailing full stop")
    func namingIsNormalised() {
        let hits = [hit("Kev's sister is Aoife.", similarity: 0.9)]
        for query in ["kev's sister is Aoife", "  Kev's   sister is Aoife.  ", "KEV'S SISTER IS AOIFE."] {
            guard case .forget = ForgetResolver.resolve(hits: hits, query: query) else {
                Issue.record("expected .forget for: \(query)"); return
            }
        }
        // ...but it is not fuzzy: a different fact is a different fact.
        #expect(
            ForgetResolver.resolve(hits: hits, query: "Kev's sister is Aoife's twin.")
                == .notConfident(closest: hits[0].memory)
        )
    }

    // MARK: - Content identity beats rank (PR #113 review)

    /// The review caught a split-store bug in the first cut of the corpus
    /// fallback: a named fact present in BOTH stores but below the floor (or
    /// simply absent from the candidate window) had its corpus twin deleted
    /// while the graph node lived on — and the caller was told "forgotten".
    /// Two stores, two different bars, for what is supposed to be one atomic
    /// forget.
    ///
    /// The fix is not a second authorisation path but a stronger first one:
    /// an EXACT content-identity match on the graph is strictly better evidence
    /// than "closest ranked neighbour ≥ 0.6", so when the caller names a fact
    /// that exists, it is forgotten whatever the cosine says.
    @Test("an exactly-named graph fact is forgotten even when rank and floor say no")
    func exactGraphMatchBeatsTheFloor() {
        let named = Memory(kind: .note, text: "The user is a curious AI.", source: "test")
        // A candidate window that does NOT contain the named fact at all — the
        // real shape from 2026-08-09 — and whose top hit clears the floor.
        let hits = [hit("The user is associated with Brightbeam AI Limited.", similarity: 0.65)]
        guard case let .forget(memory) = ForgetResolver.resolve(
            hits: hits, query: "The user is a curious AI.", exactGraphMatch: named
        ) else {
            Issue.record("expected .forget"); return
        }
        #expect(memory.text == named.text)
    }

    @Test("no exact graph match leaves the unnamed neighbour alone")
    func noExactGraphMatchStillRefuses() {
        let hits = [hit("The user is associated with Brightbeam AI Limited.", similarity: 0.65)]
        #expect(
            ForgetResolver.resolve(
                hits: hits, query: "The user is a curious AI.", exactGraphMatch: nil
            ) == .notConfident(closest: hits[0].memory)
        )
    }
}
