@testable import M1K3Knowledge
import Testing

/// A caller-supplied `limit` reaches `Collection.prefix` and a `limit * 2`
/// candidate pull unguarded. A negative limit traps `prefix`'s `maxLength >= 0`
/// precondition (an uncatchable crash reachable straight from the MCP
/// `search_knowledge` limit arg — a local, and Brain-at-Home-remote, DoS); a
/// near-`Int.max` limit overflows `limit * 2`. The store search entries must be
/// TOTAL over any Int.
struct SearchLimitClampTests {
    @Test("clampedSearchLimit floors negatives to 0 and caps the ceiling")
    func clampsToSafeRange() {
        #expect(KnowledgeStore.clampedSearchLimit(-1) == 0)
        #expect(KnowledgeStore.clampedSearchLimit(Int.min) == 0)
        #expect(KnowledgeStore.clampedSearchLimit(0) == 0)
        #expect(KnowledgeStore.clampedSearchLimit(5) == 5)
        #expect(KnowledgeStore.clampedSearchLimit(10000) == 10000)
        #expect(KnowledgeStore.clampedSearchLimit(Int.max) == 10000)
    }

    @Test("searchHybrid with a negative limit returns empty instead of trapping prefix()")
    func negativeHybridDoesNotCrash() throws {
        let store = try KnowledgeStore()
        let hits = try store.searchHybrid(query: "anything", queryVector: [0.1, 0.2, 0.3], limit: -1)
        #expect(hits.isEmpty)
    }

    @Test("searchGrounding with negative lane limits returns empty instead of trapping")
    func negativeGroundingDoesNotCrash() throws {
        let store = try KnowledgeStore()
        let hits = try store.searchGrounding(
            query: "anything", queryVector: [0.1, 0.2, 0.3], documentLimit: -1, memoryLimit: -1
        )
        #expect(hits.isEmpty)
    }

    @Test("searchHybrid with a near-Int.max limit does not overflow limit*2")
    func hugeHybridDoesNotOverflow() throws {
        let store = try KnowledgeStore()
        let hits = try store.searchHybrid(query: "anything", queryVector: [0.1, 0.2, 0.3], limit: Int.max)
        #expect(hits.isEmpty)
    }
}
