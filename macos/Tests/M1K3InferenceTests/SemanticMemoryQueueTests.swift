//
//  SemanticMemoryQueueTests.swift
//  M1K3InferenceTests
//
//  "Also get semantic memory" waits its turn: the embedder (a second ~1.3 GB fetch, an MLX load and a
//  whole-store re-index) must not start beside a brain's own download / load / swap, nor under a live
//  chat turn, nor over another re-index. The decision is pure; the shell retries it on transitions.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure decision; the shell's retry loop and the
//  real download ordering are verify-by-launch). Prior: none (new file).

@testable import M1K3Inference
import Testing

struct SemanticMemoryQueueTests {
    private static let idle = SemanticMemoryQueue.Conditions(
        brainOnDisk: true, brainFetching: false, brainLoadInFlight: false, brainSwapPending: false,
        isResponding: false, isReindexing: false, embedderSwitching: false, backgroundWorkAllowed: true
    )

    @Test("everything idle and the brain on disk: start now")
    func startsWhenIdle() {
        #expect(SemanticMemoryQueue.shouldStartNow(pending: true, Self.idle))
    }

    @Test("nothing pending: never start")
    func nothingPending() {
        #expect(!SemanticMemoryQueue.shouldStartNow(pending: false, Self.idle))
    }

    @Test("each blocker alone holds it back")
    func eachBlocker() {
        var c = Self.idle
        c.brainOnDisk = false
        #expect(!SemanticMemoryQueue.shouldStartNow(pending: true, c), "the brain's weights are not here yet")
        c = Self.idle
        c.brainFetching = true
        #expect(!SemanticMemoryQueue.shouldStartNow(pending: true, c), "two big downloads at once")
        c = Self.idle
        c.brainLoadInFlight = true
        #expect(!SemanticMemoryQueue.shouldStartNow(pending: true, c), "two MLX loads at once")
        c = Self.idle
        c.brainSwapPending = true
        #expect(!SemanticMemoryQueue.shouldStartNow(pending: true, c), "the re-index must not overlap the brain swap")
        c = Self.idle
        c.isResponding = true
        #expect(!SemanticMemoryQueue.shouldStartNow(pending: true, c), "never under a chat turn")
        c = Self.idle
        c.isReindexing = true
        #expect(!SemanticMemoryQueue.shouldStartNow(pending: true, c), "one re-index at a time")
        c = Self.idle
        c.embedderSwitching = true
        #expect(!SemanticMemoryQueue.shouldStartNow(pending: true, c), "already switching")
        c = Self.idle
        c.backgroundWorkAllowed = false
        #expect(!SemanticMemoryQueue.shouldStartNow(pending: true, c), "hot or Low Power: wait")
    }

    @Test("the brain-ready facts: on disk, not fetching, nothing loading, no swap pending")
    func brainReadyFacts() {
        #expect(SemanticMemoryQueue.isBrainReady(onDisk: true, fetching: false, loadInFlight: false, swapPending: false))
        #expect(!SemanticMemoryQueue.isBrainReady(onDisk: false, fetching: false, loadInFlight: false, swapPending: false))
        #expect(!SemanticMemoryQueue.isBrainReady(onDisk: true, fetching: true, loadInFlight: false, swapPending: false))
    }

    @Test("a request is accepted once: not while re-indexing, switching, or already pending (O3)")
    func requestGate() {
        #expect(SemanticMemoryQueue.canRequest(pending: false, isReindexing: false, embedderSwitching: false))
        #expect(!SemanticMemoryQueue.canRequest(pending: true, isReindexing: false, embedderSwitching: false))
        #expect(!SemanticMemoryQueue.canRequest(pending: false, isReindexing: true, embedderSwitching: false))
        #expect(!SemanticMemoryQueue.canRequest(pending: false, isReindexing: false, embedderSwitching: true))
    }

    @Test("the toggle says when it starts")
    func startsAfterCopy() {
        #expect(SemanticMemoryQueue.startsAfterLine(brainName: "Lil") == "Starts after Lil is ready.")
        #expect(SemanticMemoryOffer.toggleDetail(brainName: "Big") == "Better recall of your notes. Starts after Big is ready.")
    }
}
