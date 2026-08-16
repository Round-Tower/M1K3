//
//  SingleFlightLoader.swift
//  M1K3Inference
//
//  A single-flight async loader: concurrent callers share ONE in-flight load
//  instead of each kicking off their own. This replaces the check-then-act
//  NSLock MLXGemmaProvider used to cache its model container — that pattern read
//  the cache under the lock, released it, then ran the slow load with no lock
//  held, so two callers (a Settings preload racing the first generate) could both
//  pass the "not loaded yet" check and redundantly download the ~1GB container.
//
//  An actor serialises entry; the first caller starts the load and enrols as a
//  waiter before suspending, so every reentrant caller parks on the same flight.
//  On success the result is cached and returned instantly to later callers; on
//  failure the slot is cleared so a subsequent call retries rather than replaying
//  a stale error forever. Lives in the seam module (no Metal), so the concurrency
//  contract is proven under `swift test`, not stuck behind the MLX launch wall.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-08, Confidence 0.85, Prior: Unknown
//  Review: claude-opus-4-8, 2026-06-09 (PR #10) — cancelling a waiter now KEEPS the
//  slot so a later caller rejoins the still-in-flight load instead of starting a
//  duplicate download (only genuine failures clear the slot). Covered by a new test.
//  Review: Kev + claude-fable-5, 2026-07-16 (concurrency deep pass) — the PR #10
//  contract was aspirational: awaiting an unstructured Task's `.value` is NOT
//  cancellation-responsive for the waiter (proven by compiled probe — a cancelled
//  waiter blocked for the whole load, then received the value). Waiters now park
//  on per-caller continuations resumed by the flight's completion hook, wrapped in
//  withTaskCancellationHandler, so a cancelled waiter throws CancellationError
//  promptly while the flight keeps loading for everyone else. Also fixed: a load
//  that itself throws CancellationError now clears the slot (it used to be
//  mistaken for a waiter cancel and poisoned the loader with no retry path).
//  Both pinned red-first in SingleFlightLoaderTests.
//  Review: Kev + claude-fable-5, 2026-08-15 — reset() added (cache eviction
//  only; an in-flight load completes and re-caches). Pinned both ways.
//  Confidence 0.9.

import Foundation

/// Coalesces concurrent loads of a single expensive, cacheable value into one
/// in-flight operation. Generic over the loaded `Value` (e.g. an MLX
/// `ModelContainer`); the operation receives a `progress` handler so a download
/// can report a 0...1 fraction to whichever caller started it.
public actor SingleFlightLoader<Value: Sendable> {
    public typealias Operation =
        @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Value

    private let operation: Operation
    /// The one in-flight load. Non-nil exactly while the operation runs; its
    /// only job is to call `complete(_:)`, which resumes every parked waiter.
    private var flight: Task<Void, Never>?
    /// A finished successful load. Failures never land here — they clear the
    /// slot instead, so the next caller retries.
    private var cachedValue: Value?
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]

    public init(operation: @escaping Operation) {
        self.operation = operation
    }

    /// Return the loaded value, starting the operation if it isn't already in
    /// flight. Concurrent callers await the same load. `progress` is wired to the
    /// operation only for the call that actually starts it; later callers that
    /// join an in-flight (or completed) load just receive the result.
    ///
    /// Cancellation: if the calling task is cancelled, that WAITER throws
    /// `CancellationError` promptly, but the underlying load is NOT cancelled —
    /// it keeps loading and the slot is KEPT, so a later caller rejoins that
    /// same flight and receives its result rather than kicking off a duplicate
    /// download. (Matters for long-lived loaders like the WhisperKit providers,
    /// whose loader outlives any single cancelled `prepareModel` call.)
    /// A load *failure* — including the operation itself throwing
    /// `CancellationError` — clears the slot, to allow a fresh retry.
    public func value(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Value {
        if let cachedValue { return cachedValue }
        if flight == nil { startFlight(progress: progress) }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Runs synchronously in the actor with no suspension since the
                // checks above, so the flight cannot have completed in between;
                // the cached re-check is a cheap belt for future refactors.
                if let cachedValue {
                    continuation.resume(returning: cachedValue)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func startFlight(progress: @escaping @Sendable (Double) -> Void) {
        let operation = operation
        flight = Task {
            let outcome: Result<Value, Error>
            do {
                outcome = try await .success(operation(progress))
            } catch {
                outcome = .failure(error)
            }
            await self.complete(outcome)
        }
    }

    private func complete(_ outcome: Result<Value, Error>) {
        flight = nil
        if case let .success(value) = outcome {
            cachedValue = value
        }
        let parked = waiters
        waiters = [:]
        for continuation in parked.values {
            continuation.resume(with: outcome)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    /// Evict the cached value so the next caller re-runs the operation.
    /// Added 2026-08-15 for the deep-dive escalation: a parked
    /// MLXGemmaProvider's "release" freed KV caches and the Metal buffer pool
    /// but never the weights, because this cache had no eviction path — so an
    /// escalated dive ran Big beside the parked brain's resident weights
    /// against the process-global back-pressure ceiling (review catch, #130).
    ///
    /// Deliberate semantics: ONLY the cached value is evicted. An in-flight
    /// load completes and re-caches — its waiters are owed an answer, and
    /// cancelling a live download is a different feature nobody needs yet.
    /// Callers reset an IDLE loader.
    public func reset() {
        cachedValue = nil
    }
}
