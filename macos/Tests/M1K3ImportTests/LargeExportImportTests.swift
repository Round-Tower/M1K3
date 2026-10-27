//
//  LargeExportImportTests.swift
//  M1K3ImportTests
//
//  #711's scale gate: 1,000+ conversations import without blocking, at a MEASURED peak. 1,200
//  synthetic ChatGPT conversations of twenty ~1 KB messages go through parse → propose → commit →
//  forget, and every third conversation yields one accepted fact with its own vocabulary, so the
//  commit runs the real write path (embed, semantic twin search, graph dual-write) 400 times
//  before filing the transcripts. Not 1,200: each fact's twin search and graph neighbour search
//  scan the whole store, so the fact phase grows with facts × store (about 26 ms per scan of 600
//  rows in a Debug build) — the follow-up is a kind-filtered twin search. The peak
//  `phys_footprint` above the starting point is sampled at every progress tick and printed (the
//  `IMPORT FOOTPRINT` line, quoted in the PR, with MiB per MB of export) under a deliberately
//  generous ceiling; the forget's duration is printed, never bounded.
//  No wall-clock bound anywhere (tools/ci/check_wall_clock_bounds.py): "never blocks the UI" is
//  structural — the pipeline is async, cancellable and reports progress, and the import UI runs it
//  detached. A commit cancelled part-way returns what it finished, and the next commit completes
//  the rest without writing or filing anything twice.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.8 (the footprint is a whole-process
//  number, so tests running alongside add noise; the ceiling allows for it).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the gate now measures what it claimed: the old
//  fixture accepted no facts, so the twin search never ran. Facts are written and a forget leg runs; the cancel test
//  has a facts variant that lands in each phase. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — the 1,200-conversation footprint gate is opt-in now
//  (`M1K3_IMPORT_SCALE=1 swift test --filter LargeExportImportTests`, like the MLX and audio integration suites). In
//  CI's parallel run it held the 3-core runner for 45–55 s, and after #732 landed 4 of 6 PR runs went red on
//  load-sensitive server and timeout tests outside every diff (#711 comment). Run it before an import change and
//  quote its IMPORT FOOTPRINT line; the cancel-and-resume tests still run everywhere. The facts variant drops from
//  300 facts to 150 (three batches, a cancel in each phase): alone it took 22–25 s, since every fact write scans
//  the store. Confidence 0.8.

import Darwin
import Foundation
import M1K3Chat
@testable import M1K3Import
import M1K3Knowledge
import Testing

/// `phys_footprint` from task_vm_info — Activity Monitor's "Memory". The same read as
/// MLXMemoryBudget's, copied rather than linking M1K3MLX into this bundle.
private func physicalFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { infoPointer in
        infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

private final class PeakFootprint: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0

    func sample() {
        let now = physicalFootprintBytes()
        lock.withLock { peak = max(peak, now) }
    }

    var value: UInt64 {
        lock.withLock { peak }
    }
}

/// A synthetic export: `count` conversations of `messages` messages of about 1 KB each. In every
/// `factEvery`-th conversation the first user message states one fact in words no other
/// conversation uses (`fact(of:)`), so no two facts are semantic twins under the hashing embedder.
private func syntheticExport(count: Int, messages: Int = 20, factEvery: Int = 1) throws -> Data {
    let conversations = (0 ..< count).map { index in
        ChatGPTFixture.linear(
            id: "conv-\(index)", title: "Synthetic conversation \(index)",
            createTime: 1_700_000_000 + Double(index) * 60,
            messages: (0 ..< messages).map { turn in
                (
                    role: turn.isMultiple(of: 2) ? "user" : "assistant",
                    text: turn == 0 && index.isMultiple(of: factEvery)
                        ? fact(of: index) : "Message \(turn) of conversation \(index): "
                        + String(repeating: "the quick brown fox jumps over the lazy dog ", count: 23)
                )
            }
        )
    }
    return try ChatGPTFixture.data(conversations)
}

private func fact(of index: Int) -> String {
    "Kev noted " + distinctWords(index)
}

/// Proposes the slice's "Kev noted …" user line, if it has one: one fact per conversation.
private struct NotedFactDistiller: MemoryDistilling {
    func distill(turns: [ChatTurn]) async throws -> [DistilledFact] {
        turns.filter { $0.role == .user && $0.text.hasPrefix("Kev noted ") }.map { DistilledFact(text: $0.text) }
    }
}

struct LargeExportImportTests {
    /// Opt-in: a whole-process footprint over 1,200 conversations is a measurement, not a unit test, and it starves
    /// the parallel run's timing-sensitive tests on CI's three cores.
    @Test(
        "1,200 conversations parse, propose, commit 400 facts and forget, at a measured, bounded peak",
        .enabled(if: ProcessInfo.processInfo.environment["M1K3_IMPORT_SCALE"] == "1")
    )
    func largeExportFootprint() async throws {
        let baseline = physicalFootprintBytes()
        let peak = PeakFootprint()
        let data = try syntheticExport(count: 1200, factEvery: 3)
        peak.sample()
        let bundle = try ImportFormatDetector.parse(data: data)
        peak.sample()
        #expect(bundle.conversations.count == 1200)

        let harness = try ImportHarness()
        let pipeline = harness.pipeline(NotedFactDistiller())
        let log = ProgressLog()
        let proposals = try await pipeline.propose(bundle) { progress in
            log.record(progress)
            peak.sample()
        }
        let receipt = try await pipeline.commit(proposals, from: bundle, filing: .all) { progress in
            log.record(progress)
            peak.sample()
        }

        #expect(proposals.count == 400)
        #expect(receipt == ImportReceipt(factsWritten: 400, conversationsFiled: 1200))
        #expect(try harness.memory.liveCount() == 400)
        #expect(try harness.knowledge.allItems(kind: .conversation, limit: 10000).count == 1200)
        let steps = log.all()
        #expect(steps.filter { $0.phase == .proposing }.count == 1200)
        // 400 facts in batches of 50, then 1,200 transcripts.
        #expect(steps.filter { $0.phase == .committing }.count == 1208)
        #expect(steps.last == ImportProgress(phase: .committing, completed: 1208, total: 1208))
        let delta = peak.value > baseline ? peak.value - baseline : 0
        let exportMB = Double(data.count) / 1_048_576
        print(
            "IMPORT FOOTPRINT: 1200 conversations, 400 facts, export \(data.count / 1024) KiB, "
                + "peak phys_footprint +\(delta / 1_048_576) MiB over \(baseline / 1_048_576) MiB at start "
                + "(\(String(format: "%.1f", Double(delta) / 1_048_576 / exportMB)) MiB per MB of export)"
        )
        #expect(delta < 1 << 30, "peak footprint delta \(delta / 1_048_576) MiB")

        let clock = ContinuousClock()
        let began = clock.now
        let forgotten = try ImportForget.forget(
            tag: harness.tag, knowledgeStore: harness.knowledge, memoryStore: harness.memory
        )
        print("IMPORT FORGET: 400 facts + 1200 transcripts in \(began.duration(to: clock.now))")
        #expect(forgotten == ImportForgetReceipt(
            graphMemoriesForgotten: 400, corpusMemoriesForgotten: 400, conversationsForgotten: 1200
        ))
        #expect(try harness.memory.totalCount() == 0)
        #expect(try harness.knowledge.itemCount() == 0)
    }

    @Test("a cancelled commit returns what it finished; the next commit files the rest, nothing twice")
    func cancelledCommitResumes() async throws {
        let bundle = try ImportFormatDetector.parse(data: syntheticExport(count: 300, messages: 4))
        let harness = try ImportHarness()
        let pipeline = harness.pipeline(ScriptedDistiller([]))

        let interrupted = try await Task {
            try await pipeline.commit([], from: bundle, filing: .all) { progress in
                if progress.completed == 120 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }.value

        #expect(interrupted == ImportReceipt(
            factsWritten: 0, conversationsFiled: 120, conversationsAlreadyFiled: 0, wasCancelled: true
        ))
        let resumed = try await pipeline.commit([], from: bundle, filing: .all)
        #expect(resumed == ImportReceipt(factsWritten: 0, conversationsFiled: 180, conversationsAlreadyFiled: 120))
        #expect(try harness.knowledge.allItems(kind: .conversation, limit: 10000).count == 300)
    }

    /// 150 facts are three batches (steps 1-3), then 150 transcripts (steps 4-153): a cancel at step
    /// 2 lands among the facts, one at step 60 among the transcripts. Every fact write scans the whole store,
    /// so the cost grows with facts squared: 300 facts held the test at about 24 s alone, 150 keeps both phases
    /// and a mid-phase cancel in each.
    @Test("with facts, a cancel in either phase resumes to the same end: every fact once, every transcript once",
          arguments: [2, 60])
    func cancelledCommitWithFactsResumes(cancelAt: Int) async throws {
        let bundle = try ImportFormatDetector.parse(data: syntheticExport(count: 150, messages: 4))
        let harness = try ImportHarness()
        let pipeline = harness.pipeline(NotedFactDistiller())
        let proposals = try await pipeline.propose(bundle)

        let interrupted = try await Task {
            try await pipeline.commit(proposals, from: bundle, filing: .all) { progress in
                if progress.completed == cancelAt {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }.value
        let resumed = try await pipeline.commit(proposals, from: bundle, filing: .all)

        let factsFirst = min(cancelAt, 3) * 50
        let filedFirst = max(cancelAt - 3, 0)
        #expect(interrupted == ImportReceipt(
            factsWritten: factsFirst, conversationsFiled: filedFirst, wasCancelled: true
        ))
        #expect(resumed == ImportReceipt(
            factsWritten: 150 - factsFirst, conversationsFiled: 150 - filedFirst, conversationsAlreadyFiled: filedFirst
        ))
        #expect(try harness.memory.totalCount() == 150)
        #expect(try harness.memory.liveCount() == 150)
        #expect(try harness.knowledge.allItems(kind: .conversation, limit: 10000).count == 150)
    }

    @Test("a cancelled propose throws CancellationError")
    func cancelledProposeThrows() async throws {
        let bundle = try ImportFormatDetector.parse(data: syntheticExport(count: 40))
        let pipeline = try ImportHarness().pipeline(SpyDistiller())

        let outcome = await Task {
            try await pipeline.propose(bundle) { progress in
                if progress.completed == 5 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }.result

        #expect(throws: CancellationError.self) { try outcome.get() }
    }
}
