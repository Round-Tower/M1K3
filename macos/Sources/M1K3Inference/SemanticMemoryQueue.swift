//
//  SemanticMemoryQueue.swift
//  M1K3Inference
//
//  When a requested "Also get semantic memory" may actually START. The embedder is a second ~1.3 GB
//  fetch, an MLX load and a whole-store re-index: beside a brain's own download it is two big
//  downloads at once; over a brain load it is two MLX loads; across a brain swap it re-embeds while
//  the model changes under it (mixed embedding spaces mid-chat). So the surfaces (the picker, the
//  upgrade card, the kit) only REQUEST it; the shell holds it as pending and retries this decision on
//  every transition (the brain's load settling, a turn ending, a re-index ending, a fetch ending).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure; the shell's observation loop and the
//  real ordering of the two downloads are verify-by-launch). Prior: none (new file).

import Foundation

public enum SemanticMemoryQueue {
    /// Everything the decision reads, as plain facts the shell gathers.
    public struct Conditions: Equatable, Sendable {
        /// The target brain's weights are complete on disk.
        public var brainOnDisk: Bool
        /// Its weights are still arriving (the manager's fetch or the background upgrade fetch).
        public var brainFetching: Bool
        /// Any brain is loading right now (`modelLoad` downloading / preparing).
        public var brainLoadInFlight: Bool
        /// A staged brain swap for the target has not happened yet.
        public var brainSwapPending: Bool
        public var isResponding: Bool
        public var isReindexing: Bool
        public var embedderSwitching: Bool
        /// `AppEnvironment.backgroundWorkAllowed()`: not hot, not in Low Power Mode.
        public var backgroundWorkAllowed: Bool

        public init(
            brainOnDisk: Bool, brainFetching: Bool, brainLoadInFlight: Bool, brainSwapPending: Bool,
            isResponding: Bool, isReindexing: Bool, embedderSwitching: Bool, backgroundWorkAllowed: Bool
        ) {
            self.brainOnDisk = brainOnDisk
            self.brainFetching = brainFetching
            self.brainLoadInFlight = brainLoadInFlight
            self.brainSwapPending = brainSwapPending
            self.isResponding = isResponding
            self.isReindexing = isReindexing
            self.embedderSwitching = embedderSwitching
            self.backgroundWorkAllowed = backgroundWorkAllowed
        }
    }

    /// The brain half on its own: weights here, nothing fetching them, nothing loading, no swap waiting.
    public static func isBrainReady(onDisk: Bool, fetching: Bool, loadInFlight: Bool, swapPending: Bool) -> Bool {
        onDisk && !fetching && !loadInFlight && !swapPending
    }

    /// True when the pending request may start this instant.
    public static func shouldStartNow(pending: Bool, _ c: Conditions) -> Bool {
        guard pending else { return false }
        guard isBrainReady(
            onDisk: c.brainOnDisk, fetching: c.brainFetching, loadInFlight: c.brainLoadInFlight,
            swapPending: c.brainSwapPending
        ) else { return false }
        return !c.isResponding && !c.isReindexing && !c.embedderSwitching && c.backgroundWorkAllowed
    }

    /// Whether a tap may queue a request: not while a re-index is running, the embedder is switching,
    /// or one is already waiting. One request per tap, never a stamped "already re-indexing".
    public static func canRequest(pending: Bool, isReindexing: Bool, embedderSwitching: Bool) -> Bool {
        !pending && !isReindexing && !embedderSwitching
    }

    /// The toggle's "when" line, e.g. "Starts after Lil is ready."
    public static func startsAfterLine(brainName: String) -> String {
        String(localized: "Starts after \(brainName) is ready.")
    }
}
