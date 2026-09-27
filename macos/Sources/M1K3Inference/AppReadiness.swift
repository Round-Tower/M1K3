//
//  AppReadiness.swift
//  M1K3Inference
//
//  The global "is M1K3 usable yet" signal. Until the active brain's model is
//  actually loaded into memory, the chat surface should gate input — otherwise a
//  turn fires against a backend whose weights are still downloading, which is the
//  source of the "interacted before ready" latent bugs.
//
//  The subtlety this encodes: a weight-backed brain (MLX) reports `isAvailable ==
//  true` by construction ("this backend CAN serve on this Mac"), which is NOT the
//  same as "weights are present and warm". So readiness for a weight-backed brain
//  hangs on the ModelLoadState reaching `.ready`, while an instant backend (Apple
//  Foundation Models, no download) is ready the moment the system reports it
//  available. Pure + Sendable so the app can derive the gate without importing MLX.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.85 — `backendSettling`: an instant
//  backend that CAN serve here but is getting ready (AFM's transient `.modelNotReady`, which the
//  daemon reports after rapid turns) resolves to `.loading(.preparing)`, not `.unavailable`. The
//  Mac showed "This Mac can't run the selected brain" + Switch to Lil for a wait. iOS's hint
//  already told the two apart.

import Foundation

/// Whether the app is ready to take a turn, and if not, why.
public enum AppReadiness: Sendable, Equatable {
    /// The model is still warming — carries the load state so the UI can show a
    /// real progress bar / spinner / percentage.
    case loading(ModelLoadState)
    /// The active brain is loaded and can serve a turn.
    case ready
    /// The load failed; the message is human-facing.
    case failed(String)
    /// The backend can't run on this machine at all (e.g. Apple Foundation Models
    /// unavailable on this OS / hardware) and there's nothing to download.
    case unavailable

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Resolves the global readiness from the active brain's nature + load state.
public enum ModelReadiness {
    /// - Parameters:
    ///   - requiresWeights: True for a brain that must download/load weights before
    ///     it can serve (MLX). False for an instant backend (Apple Foundation Models).
    ///   - load: The current load state for the weight-backed brain (`.idle` for an
    ///     instant backend, which never downloads).
    ///   - backendAvailable: The backend's own `isAvailable` — meaningful only for
    ///     an instant backend, where it's the readiness signal.
    ///   - backendSettling: The instant backend can serve here but is getting ready
    ///     (AFM `.notReady`). A wait, so it reads as loading, never the dead end.
    public static func resolve(
        requiresWeights: Bool,
        load: ModelLoadState,
        backendAvailable: Bool,
        backendSettling: Bool = false
    ) -> AppReadiness {
        if case let .failed(message) = load { return .failed(message) }
        if requiresWeights {
            // Weight-backed: ready ONLY once the load completes. The backend's
            // always-true `isAvailable` must not be mistaken for "weights warm".
            // `backendAvailable` is deliberately NOT consulted here — MLX reports
            // `true` by construction, so there is no real "weight-backed but
            // unavailable" state to map to `.unavailable`; readiness hangs solely
            // on the load reaching `.ready`. Pinned by `weightsIgnoreAvailability`.
            if case .ready = load { return .ready }
            return .loading(load)
        }
        // Instant backend: no weights, so availability is the whole story.
        if load.isActive { return .loading(load) }
        if backendAvailable { return .ready }
        return backendSettling ? .loading(.preparing) : .unavailable
    }
}
