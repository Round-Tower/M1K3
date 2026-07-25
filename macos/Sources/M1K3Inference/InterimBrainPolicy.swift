//
//  InterimBrainPolicy.swift
//  M1K3Inference
//
//  Decides whether the chat surface must gate while the active brain warms, or
//  whether Mini (Apple Foundation Models — instant, no download) can hold the
//  fort. The 06-17 readiness gate treated "weights downloading" as a wall; this
//  narrows the wall to the states where genuinely nothing can serve a turn:
//
//    open     — the selected brain is warm; business as usual.
//    interim  — the selected weight-backed brain is still loading, but AFM is
//               available RIGHT NOW: route turns to Mini, show progress as a
//               banner, keep the input alive.
//    blocked  — nothing can serve (loading with no AFM, AFM only warming, a
//               failed load that needs its retry surface, or an unavailable
//               backend that needs its rescue buttons).
//
//  Deliberately narrow: `.failed`/`.unavailable` keep the full gate even when
//  AFM could serve — those states carry recovery affordances (retry / switch
//  brain) that a slim banner would bury.
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.9, Prior: Unknown
//

import Foundation

/// What the chat surface should do about readiness right now.
public enum ChatGate: Sendable, Equatable {
    /// Selected brain warm — no gate, no banner.
    case open
    /// Selected brain still loading; Mini serves in the meantime.
    case interim
    /// Nothing can serve a turn — mount the full ModelGateView.
    case blocked

    /// Whether a turn may be fired at all (open or interim).
    public var canTakeTurn: Bool {
        self != .blocked
    }
}

public enum InterimBrainPolicy {
    /// - Parameters:
    ///   - readiness: The resolved global readiness for the SELECTED brain.
    ///   - selectedRequiresWeights: True when the selected brain is
    ///     weight-backed (MLX). False means Mini itself is selected — its own
    ///     loading state must never "bridge to Mini" (circular).
    ///   - afm: Live Apple Foundation Models availability. Only `.available`
    ///     bridges; `.notReady` (assets still syncing) cannot serve a turn.
    public static func gate(
        readiness: AppReadiness,
        selectedRequiresWeights: Bool,
        afm: AFMAvailability
    ) -> ChatGate {
        switch readiness {
        case .ready:
            return .open
        case .loading where selectedRequiresWeights && afm == .available:
            return .interim
        case .loading, .failed, .unavailable:
            return .blocked
        }
    }
}
