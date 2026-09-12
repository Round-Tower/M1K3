//
//  ObservedSignal.swift
//  M1K3Voice
//
//  Suspend until an `@Observable` read changes — the notch HUD's wait on the
//  speech signal (#293). Three ways out, exactly one resume: the observed
//  change, a safety valve (bounds a missed observation), or the waiting
//  task's cancellation. The valve task is cancelled the moment the wait
//  resolves, so a quiet caller holds no timer beyond its wait. Lifted out of
//  `NotchHUDController` after three review passes each found a race in the
//  app-target original — this is logic, not glue, so it lives where it can
//  be pinned (`ObservedSignalTests`).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85 (the three
//  interleavings — change / valve / cancel, including a cancel that lands
//  before the wait arms — are test-pinned; the `withObservationTracking`
//  one-shot semantics are Apple's). Prior: Unknown.
//

import Foundation
import Observation
import os

public enum ObservedSignal {
    /// Suspend until something `read` touches changes, `valve` elapses, or
    /// the current task is cancelled — whichever comes first. `read` runs
    /// synchronously, once, before the suspension; it must touch the
    /// `@Observable` properties whose change should wake the caller
    /// (`withObservationTracking` observes one change, then stops).
    @MainActor
    public static func waitForChange(valve: Duration, of read: () -> Void) async {
        let hook = OSAllocatedUnfairLock<ResumeOnce?>(initialState: nil)
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(continuation)
                // Publish the hook FIRST, then re-check the flag: a cancel that
                // raced this setup set `isCancelled` before its `onCancel` ran
                // (and found no hook), so it resumes here instead of never.
                hook.withLock { $0 = once }
                if Task.isCancelled {
                    once.resume()
                    return
                }
                withObservationTracking {
                    read()
                } onChange: {
                    once.resume()
                }
                once.attach(valve: Task {
                    try? await Task.sleep(for: valve)
                    once.resume()
                })
            }
        }, onCancel: {
            hook.withLock { $0 }?.resume()
        })
    }

    /// A continuation that resumes at most once, from whichever of the
    /// observation callback / valve / cancellation gets there first — and
    /// cancels the valve on the way out so nothing keeps sleeping for it.
    private final class ResumeOnce: Sendable {
        private struct State {
            var continuation: CheckedContinuation<Void, Never>?
            var valve: Task<Void, Never>?
        }

        private let slot: OSAllocatedUnfairLock<State>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            slot = OSAllocatedUnfairLock(initialState: State(continuation: continuation))
        }

        /// Register the safety valve; if the wait already resolved, cancel it now.
        func attach(valve: Task<Void, Never>) {
            let resolved = slot.withLock { state -> Bool in
                guard state.continuation != nil else { return true }
                state.valve = valve
                return false
            }
            if resolved { valve.cancel() }
        }

        func resume() {
            let taken = slot.withLock { state -> (CheckedContinuation<Void, Never>?, Task<Void, Never>?) in
                defer {
                    state.continuation = nil
                    state.valve = nil
                }
                return (state.continuation, state.valve)
            }
            taken.1?.cancel()
            taken.0?.resume()
        }
    }
}
