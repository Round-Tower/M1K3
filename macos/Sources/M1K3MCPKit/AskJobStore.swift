//
//  AskJobStore.swift
//  M1K3MCPKit
//
//  The job registry behind ask_m1k3's submit-and-poll path. A long local turn
//  (web search + a verbose thinker) can out-run the MCP client's ~60s request
//  deadline, so ask_m1k3 no longer blocks on the whole generation: it submits a
//  job here, waits a short grace window for the fast case, and otherwise returns
//  a job id the client fetches later via get_answer. The generation runs
//  detached and writes its result back here when it finishes.
//
//  Pure actor — no inference/store links — so the lifecycle is unit-tested with
//  injected id/clock. Survives across the stateless HTTP transport's per-request
//  sessions because the host builds ONE store and captures it in the tool
//  closures (which outlive every request).
//
//  Signed: Kev + claude-opus-4-8, 2026-07-01, Confidence 0.85 (lifecycle
//  TDD'd; the live generation write-back is verify-by-launch). Prior: Unknown.
//
//  Review: Kev + claude-fable-5, 2026-08-19, Confidence 0.9. Added the
//  payload-free JobSummary listing (list_jobs — recovery for a dropped id) and
//  runningJobIDs (the honest-busy check). Submission order via an explicit
//  sequence counter, not clock ties. TDD'd.

import Foundation

public actor AskJobStore {
    public enum Status: Sendable, Equatable {
        case running
        case done(String)
        case error(String)
    }

    /// One row of the `list_jobs` recovery listing. Deliberately payload-free —
    /// ids, state, and age only — so the listing can never become a second
    /// answer channel (answers are redeemed through get_answer alone).
    public struct JobSummary: Sendable, Equatable {
        public let id: String
        /// "running" | "done" | "error" — the state NAME, never the payload.
        public let state: String
        /// Seconds since the job was submitted.
        public let ageSeconds: Int
    }

    private struct Job {
        var status: Status
        var finishedAt: Date?
        var createdAt: Date
        /// Monotonic submission order — dictionaries don't remember it.
        var sequence: Int
    }

    /// Terminal jobs older than this are evicted opportunistically on submit —
    /// bounds memory on a long-lived server without a background timer.
    static let jobRetention: TimeInterval = 600

    private let makeID: @Sendable () -> String
    private let now: @Sendable () -> Date
    private var jobs: [String: Job] = [:]
    private var nextSequence = 0

    public init(
        makeID: @escaping @Sendable () -> String = { UUID().uuidString },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeID = makeID
        self.now = now
    }

    /// Register a new running job and return its id. Reaps stale terminal jobs
    /// first so the map can't grow unbounded across a long session.
    public func submit() -> String {
        reap(olderThan: Self.jobRetention)
        let id = makeID()
        nextSequence += 1
        jobs[id] = Job(status: .running, finishedAt: nil, createdAt: now(), sequence: nextSequence)
        return id
    }

    public func complete(id: String, result: String) {
        finish(id: id, status: .done(result))
    }

    public func fail(id: String, message: String) {
        finish(id: id, status: .error(message))
    }

    /// The current status, or nil if the id is unknown (never submitted, or reaped).
    public func status(of id: String) -> Status? {
        jobs[id]?.status
    }

    /// Ids of jobs still generating, oldest first — the busy check reads the
    /// head (the job a new question would collide with on the single-flight
    /// app lock).
    public func runningJobIDs() -> [String] {
        jobs.filter { _, job in job.status == .running }
            .sorted { $0.value.sequence < $1.value.sequence }
            .map(\.key)
    }

    /// Every retained job, newest submission first — the `list_jobs` recovery
    /// index for a client that dropped its ticket. Payload-free by type.
    public func summaries() -> [JobSummary] {
        let current = now()
        return jobs.sorted { $0.value.sequence > $1.value.sequence }.map { id, job in
            let state = switch job.status {
            case .running: "running"
            case .done: "done"
            case .error: "error"
            }
            return JobSummary(
                id: id,
                state: state,
                ageSeconds: Int(current.timeIntervalSince(job.createdAt).rounded())
            )
        }
    }

    /// Evict terminal (done/error) jobs whose finish time is older than `ttl`.
    /// Running jobs are always kept. Returns how many were removed.
    @discardableResult
    public func reap(olderThan ttl: TimeInterval) -> Int {
        let cutoff = now().addingTimeInterval(-ttl)
        let before = jobs.count
        jobs = jobs.filter { _, job in
            guard let finishedAt = job.finishedAt else { return true } // keep running jobs
            return finishedAt > cutoff
        }
        return before - jobs.count
    }

    /// A terminal transition wins only over `.running` — a late completion can't
    /// clobber an already-failed job, and an unknown id is a safe no-op.
    private func finish(id: String, status: Status) {
        guard var job = jobs[id], case .running = job.status else { return }
        job.status = status
        job.finishedAt = now()
        jobs[id] = job
    }
}
