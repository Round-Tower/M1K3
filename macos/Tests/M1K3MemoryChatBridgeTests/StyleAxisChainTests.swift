//
//  StyleAxisChainTests.swift
//  M1K3MemoryChatBridgeTests
//
//  #699 pre-push review fold: the axis supersede makes chains of three style asks routine
//  ("short", "long, detailed", "brief"), and a revive over one used to demote only the one-hop
//  corrector in the corpus, so "short" again left "brief" live in retrieval too: the next
//  "brief" was swallowed as a duplicate, and a forget restored the wrong row. Pinned over the
//  real stores (StyleAxisRig): the revive demotes the chain's LIVE head, and the corpus agrees
//  with the graph through a later revive and a forget.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85. Prior: none (new file).
//

import Foundation
@testable import M1K3Chat
@testable import M1K3Knowledge
import M1K3Memory
@testable import M1K3MemoryChatBridge
import Testing

struct StyleAxisChainTests {
    @Test("a revive over a chain demotes the chain's live head: short, long, brief, short leaves short alone")
    func reviveOverAChain() async throws {
        let rig = try StyleAxisRig()
        let short = "The user prefers short answers."
        let long = "The user prefers long, detailed answers."
        let brief = "The user prefers brief answers."
        for text in [short, long, brief] {
            try await rig.say(text)
        }
        #expect(try await rig.say(short) == 1) // a revive

        #expect(try rig.liveStyles() == [short])
        #expect(try rig.corpusLive() == [short])
        #expect(try rig.corpusKind(long) == .memorySuperseded)
        #expect(try rig.corpusKind(brief) == .memorySuperseded)

        // Saying the head again is a revive in its turn, never a duplicate swallowed.
        #expect(try await rig.say(brief) == 1)
        #expect(try rig.liveStyles() == [brief])
        #expect(try rig.corpusLive() == [brief])
    }

    @Test("forgetting a revive over a chain brings back the head it retired, the same in both stores")
    func forgetAfterAChainRevive() async throws {
        let rig = try StyleAxisRig()
        let short = "The user prefers short answers."
        let long = "The user prefers long, detailed answers."
        let brief = "The user prefers brief answers."
        for text in [short, long, brief, short] {
            try await rig.say(text)
        }

        _ = try rig.editor().forget(#require(try rig.liveNode(short)).id)

        #expect(try rig.liveStyles() == [brief])
        #expect(try rig.corpusLive() == [brief])
        #expect(try rig.corpusKind(long) == .memorySuperseded)
        #expect(try rig.corpusKind(short) == nil)
    }
}
