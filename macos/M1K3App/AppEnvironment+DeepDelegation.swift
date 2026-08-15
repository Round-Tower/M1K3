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
//  Review: Kev + claude-fable-5, 2026-08-15 — the DeepDiveTarget wiring: where
//  Big's weights are on disk and this Mac clears the 24GB comfort bar, the
//  dive re-points the ONE MLX slot at a fresh Big provider and restores the
//  parked resident on every exit (finishDeepDelegation is the single teardown
//  point; success and failure both funnel there). The slot — not a private
//  provider — so stray mid-dive callers queue on Big's container actor rather
//  than decoding concurrently on the parked brain. Confidence 0.8 — the plan
//  and observation copy are unit-pinned; the swap/restore is app glue and
//  verify-by-launch (a real cross-brain dive has still never run).
//

import AppKit
import Foundation
import M1K3Chat
import M1K3Inference
import M1K3MLX
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

        // Where should this dive run? DeepDiveTarget escalates to Big only when
        // its weights are already on disk AND this Mac clears the 24GB comfort
        // bar (both refusals argued in its header); everywhere else the dive
        // stays on the resident brain — the pre-2026-08-15 behaviour.
        let plan = DeepDiveTarget.plan(
            resident: selectedBrain,
            bigWeightsPresent: isBrainDownloaded(.big),
            physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        )
        deepDelegationTaskLabel = task
        if plan.requiresSwap, let bigID = BrainTier.big.mlxModelID {
            // Re-point the ONE MLX slot at Big for the dive's lifetime. The
            // slot (not a private provider) on purpose: any stray caller that
            // reaches swappableMLX mid-dive then QUEUES on Big's container
            // actor instead of spinning a second concurrent MLX decode loop on
            // the parked brain — the one-decode-loop invariant this whole
            // design rests on. `selectBrain` already refuses while the label is
            // set, so nothing else re-points the slot underneath us.
            let big = MLXGemmaProvider(
                modelID: bigID,
                maxTokens: HistoryBudgetPolicy.generationTokenCap(
                    for: .big, defaultCap: MLXGemmaProvider.defaultMaxTokens
                )
            )
            deepDiveRestoreProvider = currentMLXProvider
            deepDiveEscalatedProvider = big
            swappableMLX.setProvider(big)
            // Free the parked brain's Metal footprint before the 12B load; it
            // reloads lazily (ensureLoaded) once the slot is restored. Weights
            // are on disk by the plan's own gate, so the dive's first generate
            // loads from disk — never a download.
            deepDiveRestoreProvider?.releaseMemory()
        }
        refreshInterimBridge() // interactive turns front on Mini from here
        Self.logDelegation(.started(brain: plan.isEscalation
                ? "\(plan.tier.displayName) (escalated from \(selectedBrain.displayName))"
                : plan.tier.displayName))
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
        return DeepDiveObservation.delegated(plan: plan)
    }

    /// Delivery + teardown, always on the main actor. The task handle clears
    /// FIRST so a delivery that itself takes time can't block a new delegation.
    private func finishDeepDelegation(delivered: String, elapsed: Duration) async {
        deepDelegationTaskLabel = nil
        deepDelegationTask = nil
        // Restore the slot BEFORE fronting returns to the selected brain, so no
        // interactive turn can land on the dive's Big provider. This block and
        // the label-clear above run in the same synchronous main-actor window —
        // no suspension separates them, so selectBrain can't slip between.
        if let restore = deepDiveRestoreProvider {
            swappableMLX.setProvider(restore)
            deepDiveEscalatedProvider?.releaseMemory()
            deepDiveEscalatedProvider = nil
            deepDiveRestoreProvider = nil
            // Hoisted local: the Logger interpolation is an autoclosure, so a
            // bare property read needs `self.` — which the formatter strips.
            let restoredName = selectedBrain.displayName
            Self.delegationLog.notice(
                "delegate_deep escalation ended — slot restored to \(restoredName, privacy: .public)"
            )
            // The parked provider reloads lazily; rebuild weights + persona
            // prefix off the hot path so the next interactive turn doesn't pay
            // the cold load inline.
            warmPersonaPrefixAfterLoad(restore)
        }
        refreshInterimBridge() // interactive turns return to the selected brain
        Self.delegationLog.notice(
            "delegate_deep finished in \(elapsed.components.seconds, privacy: .public)s"
        )
        await chat.deliverBackgroundAnswer(delivered)
        await maybeNotifyDeepDiveFinished(appActive: NSApp.isActive)
    }
}
