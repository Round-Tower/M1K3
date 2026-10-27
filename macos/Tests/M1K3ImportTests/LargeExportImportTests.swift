//
//  LargeExportImportTests.swift
//  M1K3ImportTests
//
//  #711's scale gate: 1,000+ conversations import without blocking, at a MEASURED peak. 1,200
//  synthetic ChatGPT conversations of six messages go through parse → propose → commit; the peak
//  `phys_footprint` above the starting point is sampled at every progress tick and printed (the
//  `IMPORT FOOTPRINT` line, quoted in the PR) under a deliberately generous ceiling. No wall-clock
//  bound anywhere (tools/ci/check_wall_clock_bounds.py): "never blocks the UI" is structural —
//  the pipeline is async, cancellable and reports progress, and the import UI runs it detached.
//  A commit cancelled part-way returns what it finished, and the next commit completes the rest
//  without filing anything twice.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.8 (the footprint is a whole-process
//  number, so tests running alongside add noise; the ceiling allows for it).
//  Prior: none (new file).

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

/// A synthetic export: `count` conversations of six messages, about 300 characters each.
private func syntheticExport(count: Int) throws -> Data {
    let conversations = (0 ..< count).map { index in
        ChatGPTFixture.linear(
            id: "conv-\(index)", title: "Synthetic conversation \(index)",
            createTime: 1_700_000_000 + Double(index) * 60,
            messages: (0 ..< 6).map { turn in
                (
                    role: turn.isMultiple(of: 2) ? "user" : "assistant",
                    text: "Message \(turn) of conversation \(index): "
                        + String(repeating: "the quick brown fox jumps over the lazy dog ", count: 6)
                )
            }
        )
    }
    return try ChatGPTFixture.data(conversations)
}

struct LargeExportImportTests {
    @Test("1,200 conversations parse, propose and commit with progress at a measured, bounded peak")
    func largeExportFootprint() async throws {
        let baseline = physicalFootprintBytes()
        let peak = PeakFootprint()
        let data = try syntheticExport(count: 1200)
        peak.sample()
        let bundle = try ImportFormatDetector.parse(data: data)
        peak.sample()
        #expect(bundle.conversations.count == 1200)

        let harness = try ImportHarness()
        let pipeline = harness.pipeline(ScriptedDistiller([]))
        let log = ProgressLog()
        let proposals = try await pipeline.propose(bundle) { progress in
            log.record(progress)
            peak.sample()
        }
        let receipt = try await pipeline.commit(proposals, from: bundle) { progress in
            log.record(progress)
            peak.sample()
        }

        #expect(proposals.isEmpty)
        #expect(receipt == ImportReceipt(factsWritten: 0, conversationsFiled: 1200, conversationsAlreadyFiled: 0))
        #expect(try harness.knowledge.allItems(kind: .conversation, limit: 10000).count == 1200)
        let steps = log.all()
        #expect(steps.filter { $0.phase == .proposing }.count == 1200)
        #expect(steps.filter { $0.phase == .committing }.count == 1200)
        #expect(steps.last == ImportProgress(phase: .committing, completed: 1200, total: 1200))
        let delta = peak.value > baseline ? peak.value - baseline : 0
        print(
            "IMPORT FOOTPRINT: 1200 conversations, export \(data.count / 1024) KiB, "
                + "peak phys_footprint +\(delta / 1_048_576) MiB over \(baseline / 1_048_576) MiB at start"
        )
        #expect(delta < 1 << 30, "peak footprint delta \(delta / 1_048_576) MiB")
    }

    @Test("a cancelled commit returns what it finished; the next commit files the rest, nothing twice")
    func cancelledCommitResumes() async throws {
        let bundle = try ImportFormatDetector.parse(data: syntheticExport(count: 300))
        let harness = try ImportHarness()
        let pipeline = harness.pipeline(ScriptedDistiller([]))

        let interrupted = try await Task {
            try await pipeline.commit([], from: bundle) { progress in
                if progress.completed == 120 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }.value

        #expect(interrupted == ImportReceipt(
            factsWritten: 0, conversationsFiled: 120, conversationsAlreadyFiled: 0, wasCancelled: true
        ))
        let resumed = try await pipeline.commit([], from: bundle)
        #expect(resumed == ImportReceipt(factsWritten: 0, conversationsFiled: 180, conversationsAlreadyFiled: 120))
        #expect(try harness.knowledge.allItems(kind: .conversation, limit: 10000).count == 300)
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
