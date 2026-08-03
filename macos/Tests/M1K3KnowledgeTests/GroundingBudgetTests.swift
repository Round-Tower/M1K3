//
//  GroundingBudgetTests.swift
//  M1K3KnowledgeTests
//
//  Red-first for the grounding-size safety cap: the KNOWLEDGE (chunks) and
//  memory lanes AgentRAGResponder injects verbatim into the prompt, capped at
//  the source before gemma-4's fixed non-history reserve can be blown (PR
//  #65's on-device measurement: grounded-Q worst case landed at 2998/3000
//  tokens). A deterministic char-count `countTokens` fake makes every case
//  exact — no real tokenizer needed to pin the policy's arithmetic.
//
//  Signed: Kev + claude-fable-5, 2026-07-20, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3Knowledge
import Testing

struct GroundingBudgetTests {
    private func chunk(_ content: String, title: String = "Doc", heading: String? = "H") -> ChunkHit {
        ChunkHit(chunkID: UUID(), itemID: UUID(), itemTitle: title, kind: .document, heading: heading, content: content)
    }

    private func memory(_ content: String) -> ChunkHit {
        ChunkHit(chunkID: UUID(), itemID: UUID(), itemTitle: "Memory", kind: .memory, heading: nil, content: content)
    }

    /// Token count == character count. Exact and reproducible: with
    /// itemTitle "Doc" + heading "H", a chunk's rendered head "N. [Doc §H]\n"
    /// is always 11 characters for a single-digit N ("1. [Doc §H]\n" — count
    /// it: '1','.',' ','[','D','o','c',' ','§','H',']','\n' = 12). Individual
    /// tests still compute their own expected costs rather than trust this
    /// comment — this is context, not a magic number to copy blindly.
    private func charCounter(_ text: String) async -> Int? {
        text.count
    }

    // MARK: - No-op paths

    @Test("under budget: every unit passes through unchanged")
    func underBudgetIsNoOp() async {
        let chunks = [chunk("short")]
        let memories = [memory("also short")]
        let result = await GroundingBudget.fit(
            chunks: chunks, memories: memories, tokenBudget: 1000, countTokens: charCounter
        )
        #expect(result.chunks == chunks)
        #expect(result.memories == memories)
    }

    @Test("empty inputs stay empty")
    func emptyInputsEmptyOut() async {
        let result = await GroundingBudget.fit(
            chunks: [], memories: [], tokenBudget: 1000, countTokens: charCounter
        )
        #expect(result.chunks.isEmpty)
        #expect(result.memories.isEmpty)
    }

    @Test("no tokenizer (countTokens returns nil): the cap still applies, on an estimate")
    func nilTokenizerStillCaps() async {
        // This test previously asserted the OPPOSITE — that a nil tokenizer made
        // the cap a no-op "even for huge inputs" — on the belief recorded in
        // TokenCounting.swift that a provider without a tokenizer "self-manages
        // its own context window, there is nothing to measure or cap".
        //
        // Apple Foundation Models does not self-manage. Interviewing Mini over
        // MCP on 2026-08-03 produced, verbatim from the SDK:
        //
        //   exceededContextWindowSize: "Content contains 4486 tokens, which
        //   exceeds the maximum allowed context size of 4096."
        //
        // Mini is the ONLY tier without a tokenizer AND has the SMALLEST window
        // (4096 vs the MLX tiers' 8192) — so the one brain that most needs a
        // grounding cap was the only one exempt from it. "Unmeasurable" must
        // never mean "unlimited": a budget that fails open is not a budget.
        let huge = [chunk(String(repeating: "x", count: 50000))]
        let hugeMemories = [memory(String(repeating: "y", count: 50000))]
        let result = await GroundingBudget.fit(
            chunks: huge, memories: hugeMemories, tokenBudget: 10, countTokens: { _ in nil }
        )
        // The keep-at-least-one rule still holds, so the top unit survives —
        // truncated to fit rather than passed through whole.
        #expect(result.chunks.count == 1)
        #expect(result.memories.isEmpty)
        #expect(result.chunks[0].content.count < 1000)
        #expect(result.chunks[0].content.hasSuffix(" …[truncated]"))
    }

    @Test("an exact count is preferred over the estimate when the provider has one")
    func exactCountWinsOverEstimate() async {
        // The estimate is a floor under the fail-open hole, not a replacement
        // for a real tokenizer: when countTokens answers, that answer rules.
        // Here the text would ESTIMATE far over budget but measures as cheap.
        let long = [chunk(String(repeating: "x", count: 4000))]
        let result = await GroundingBudget.fit(
            chunks: long, memories: [], tokenBudget: 100, countTokens: { _ in 5 }
        )
        #expect(result.chunks == long)
        #expect(result.chunks[0].content.count == 4000)
    }

    // MARK: - Over-budget dropping

    @Test("over budget: lowest-ranked whole chunks are dropped, the kept total fits")
    func overBudgetDropsTail() async {
        // Each chunk renders to the SAME length: "N. [Doc §H]\n" (12 chars,
        // single-digit N) + a 20-char body == 32 tokens under charCounter.
        let a = chunk(String(repeating: "a", count: 20))
        let b = chunk(String(repeating: "b", count: 20))
        let c = chunk(String(repeating: "c", count: 20))
        let unitCost = 32
        let result = await GroundingBudget.fit(
            chunks: [a, b, c], memories: [], tokenBudget: unitCost * 2, countTokens: charCounter
        )
        #expect(result.chunks == [a, b])
        #expect(result.memories.isEmpty)
    }

    @Test("memories share the budget with chunks — chunks fill first, in rank order")
    func memoriesShareRemainingBudgetAfterChunks() async {
        let a = chunk(String(repeating: "a", count: 20)) // 32 tokens (see above)
        let m1 = memory("MM") // "- MM" == 4 tokens
        let m2 = memory("NN") // "- NN" == 4 tokens
        // Exactly enough for the chunk + the first memory; the second memory
        // would need 4 more tokens than remain.
        let result = await GroundingBudget.fit(
            chunks: [a], memories: [m1, m2], tokenBudget: 32 + 4, countTokens: charCounter
        )
        #expect(result.chunks == [a])
        #expect(result.memories == [m1])
    }

    // MARK: - Truncation of the single top unit

    @Test("single top chunk alone exceeds the whole budget: kept, truncated, never empty")
    func singleOversizedTopChunkIsTruncatedNotDropped() async {
        let big = chunk(String(repeating: "X", count: 500))
        // Head "1. [Doc §H]\n" == 12 tokens; marker " …[truncated]" == 13
        // tokens (space, ellipsis, "[truncated]" == 11 chars). Budget 30
        // leaves 30 - 12 - 13 == 5 tokens of body.
        let result = await GroundingBudget.fit(
            chunks: [big], memories: [], tokenBudget: 30, countTokens: charCounter
        )
        #expect(result.chunks.count == 1)
        let kept = result.chunks.first
        #expect(kept?.content == String(repeating: "X", count: 5) + " …[truncated]")
        // The citation label's own fields (title/heading) are untouched —
        // the head stays intact downstream, only the body tail is cut.
        #expect(kept?.itemTitle == big.itemTitle)
        #expect(kept?.heading == big.heading)
        #expect(result.memories.isEmpty)
    }

    @Test("single top MEMORY alone exceeds the whole budget: kept, truncated, never empty")
    func singleOversizedTopMemoryIsTruncatedNotDropped() async {
        let big = memory(String(repeating: "Y", count: 500))
        let result = await GroundingBudget.fit(
            chunks: [], memories: [big], tokenBudget: 20, countTokens: charCounter
        )
        #expect(result.memories.count == 1)
        #expect(result.chunks.isEmpty)
        #expect(result.memories.first?.content.hasSuffix(" …[truncated]") == true)
        #expect(!(result.memories.first?.content.isEmpty ?? true))
    }
}
