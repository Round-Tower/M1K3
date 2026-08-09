//
//  AppEnvironment+DeepDelegation.swift
//  M1K3App
//
//  delegate_deep's manager (Kev, 2026-07-25: "Lil could delegate a long-form
//  task and notify the user when it's back — everything stays quick"). The
//  challenger-hardened shape: the delegated run executes on the ONE resident
//  MLX slot (`swappableMLX`, reached directly so the façade's override can't
//  reroute it) while interactive turns front on Mini via the same
//  `refreshInterimBridge()` override the download bridge uses — one MLX decode
//  loop ever, because the process-global memory budget makes two concurrent
//  MLX generations stall each other (see DeepDelegationPolicy's header).
//
//  Eligibility/single-flight copy is model-facing ("Error: …" observations,
//  never throws — the AgentTool contract). Delivery: the finished answer joins
//  the transcript via ChatSession.deliverBackgroundAnswer + the house
//  notification gate (opted-in AND backgrounded).
//
//  Known v1 limits, named: the delegation dies with the app (in-memory only —
//  no relaunch resume); delivery lands in whatever conversation is ACTIVE at
//  finish time; the delegated run's tool sources aren't threaded, so citations
//  arrive as plain text.
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.85 (policy + tool +
//  delivery are unit-pinned; the manager itself is app glue over those seams —
//  concurrency behaviour is verify-by-launch). Prior: Unknown.
//

import AppKit
import Foundation
import M1K3Inference
import os
import Synchronization

/// Late-bound bridge from the tool palette (built during init, before `self`
/// exists) to the manager: the tool holds this box; the handler is installed
/// at the end of init beside `wireSpeechCallbacks()`. Lock-protected because
/// the tool executes off the main actor.
final class DeepDelegationHook: Sendable {
    private let handler = Mutex<(@Sendable (String) async -> String)?>(nil)

    func install(_ newHandler: @escaping @Sendable (String) async -> String) {
        handler.withLock { $0 = newHandler }
    }

    func invoke(_ task: String) async -> String {
        guard let installed = handler.withLock({ $0 }) else {
            return "Error: M1K3 is still waking up — try again in a moment."
        }
        return await installed(task)
    }
}

extension AppEnvironment {
    private static let delegationLog = Logger(subsystem: "app.m1k3", category: "mlx-load")

    /// One `.notice` per delegate_deep invocation, whatever became of it.
    /// `.notice` and not `.info`/`.debug`: those don't persist in OSLogStore,
    /// and the whole point is that a later `rg 'delegate_deep '` over days of
    /// log can tell "never called" from "always refused".
    static func logDelegation(_ outcome: DeepDelegationOutcome) {
        delegationLog.notice("\(outcome.logLine, privacy: .public)")
    }

    /// Start a background deep dive. Returns the tool observation for the
    /// fronting model — delegated, single-flight refusal, or an eligibility
    /// refusal (DeepDelegationPolicy).
    func startDeepDelegation(_ task: String) async -> String {
        if let running = deepDelegationTaskLabel {
            Self.logDelegation(.declined(reason: .alreadyRunning))
            return "Error: already digging into “\(running)” — one deep dive at a "
                + "time. Offer to queue the new one for after, or answer it directly."
        }
        let eligibility = DeepDelegationPolicy.eligibility(
            selectedRequiresWeights: selectedBrain.mlxModelID != nil,
            load: modelLoad,
            afm: afmAvailability
        )
        // Both halves of a refusal, together: `refusalObservation` is what the
        // model hears, `declineReason` is what we see. They are pinned in
        // lockstep (DeepDelegationOutcomeTests) precisely so a refusal can never
        // again be spoken to the model while leaving no trace for us.
        //
        // Requiring BOTH to unwrap is safe rather than merely lucky: each is an
        // exhaustive `switch` over `Eligibility` with NO `default:`, so adding a
        // case fails to compile until both are extended. The compiler enforces
        // the pairing; the test documents it. If either ever gained a `default:`
        // this double-bind would silently start swallowing refusals — so don't.
        if let reason = eligibility.declineReason, let refusal = eligibility.refusalObservation {
            Self.logDelegation(.declined(reason: reason))
            return refusal
        }

        let brainName = selectedBrain.displayName
        deepDelegationTaskLabel = task
        refreshInterimBridge() // interactive turns front on Mini from here
        Self.logDelegation(.started(brain: brainName))
        // Ask for notification permission NOW so the finish ping can land
        // (no-op if already granted/denied; the center drops unauthorized posts).
        Task { _ = await TurnNotifier.requestAuthorization() }

        // The delegation lane's own responder, aimed STRAIGHT at the MLX slot —
        // not the runtime façade, whose override is about to route interactive
        // turns to Mini. Fresh per delegation (cheap wiring, no model load).
        let deepResponder = Self.makeAgentResponder(
            store: store,
            embedder: embedder,
            provider: swappableMLX
        )
        deepDelegationTask = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            var delivered: String
            do {
                let (_, stream) = try await deepResponder.answerStreaming(task)
                var text = ""
                for await delta in stream {
                    text += delta
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                delivered = trimmed.isEmpty
                    ? "The deep dive on “\(task)” came back empty — nothing to report."
                    : "Deep dive — \(task)\n\n\(trimmed)"
            } catch {
                delivered = "The deep dive on “\(task)” hit a wall: \(error.localizedDescription)"
            }
            let elapsed = clock.now - start
            await self?.finishDeepDelegation(delivered: delivered, elapsed: elapsed)
        }
        return "Delegated to \(brainName). It's digging in the background; the result "
            + "will land in this chat (with a ping if the user is away). Tell the user "
            + "it's underway and that quicker replies come from Mini until it's done."
    }

    /// Delivery + teardown, always on the main actor. The task handle clears
    /// FIRST so a delivery that itself takes time can't block a new delegation.
    private func finishDeepDelegation(delivered: String, elapsed: Duration) async {
        deepDelegationTaskLabel = nil
        deepDelegationTask = nil
        refreshInterimBridge() // interactive turns return to the selected brain
        Self.delegationLog.notice(
            "delegate_deep finished in \(elapsed.components.seconds, privacy: .public)s"
        )
        await chat.deliverBackgroundAnswer(delivered)
        await maybeNotifyDeepDiveFinished(appActive: NSApp.isActive)
    }
}
