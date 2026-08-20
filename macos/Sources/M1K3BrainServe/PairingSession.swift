//
//  PairingSession.swift
//  M1K3BrainServe
//
//  The pure pairing state machine behind Brain at Home's one-time QR ceremony
//  (BRAIN_AT_HOME_SPEC §4). The load-bearing security property is audit B2 —
//  prevention, not detection: completing a handshake against a DISPLAYED
//  (uncommitted) secret does NOT pair. Nothing is committed until the human
//  clicks Approve, and the structural half of that guarantee lives outside
//  this type: the candidate secret only ever loads into a separate, short-
//  lived PAIRING listener that serves nothing but /v1/pair — the main
//  listener never holds it, so a candidate can't reach /v1/generate by
//  construction.
//
//  This machine never holds the secret BYTES — only the identity label. The
//  controller owns the bytes and writes them to the Keychain exactly once,
//  on approve.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.9 (pure, TDD'd
//  red-first; the listener split it documents is verified by the SelfTest
//  probe + launch). Prior: scratch/brain-at-home/SPEC.md §4.
//

import Foundation

/// A device the user approved. Metadata only — the PSK lives in the Keychain
/// under `identity`.
public struct PairedDevice: Sendable, Equatable, Codable, Identifiable {
    public var id: String {
        identity
    }

    /// The opaque PSK identity (audit S1: random, never a device name).
    public let identity: String
    /// The device's self-reported display name, shown in the paired list.
    public let name: String
    public let addedAt: Date

    public init(identity: String, name: String, addedAt: Date) {
        self.identity = identity
        self.name = name
        self.addedAt = addedAt
    }
}

public struct PairingSession: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// The QR is on screen; a candidate secret exists but is uncommitted.
        case displaying(identity: String, expiresAt: Date)
        /// A device completed the pairing handshake and asked to pair —
        /// waiting on the human (audit B2).
        case awaitingApproval(candidateName: String, identity: String)
    }

    /// The QR's lifetime (§4: auto-expires; a stale screenshot is useless
    /// because the secret is only committed on approve).
    public static let displayTTL: TimeInterval = 60

    public private(set) var phase: Phase = .idle

    public init() {}

    /// Show a fresh QR. A previous DISPLAYED candidate is discarded
    /// (regenerate) — but a candidate already awaiting the human's Approve is
    /// never silently clobbered: the decision must be made (or cancelled)
    /// explicitly first, so a stray re-display can't vanish a pending device
    /// (2026-08-19 audit, note 11). Returns false when refused for that reason.
    @discardableResult
    public mutating func beginDisplay(identity: String, now: Date) -> Bool {
        if case .awaitingApproval = phase { return false }
        phase = .displaying(identity: identity, expiresAt: now.addingTimeInterval(Self.displayTTL))
        return true
    }

    /// Clock tick: an expired QR falls back to idle. Returns true when this
    /// tick expired it (the controller tears the pairing listener down).
    /// `awaitingApproval` never expires by clock — a human is mid-decision.
    @discardableResult
    public mutating func tick(now: Date) -> Bool {
        guard case let .displaying(_, expiresAt) = phase, now >= expiresAt else { return false }
        phase = .idle
        return true
    }

    /// A device completed the TLS handshake on the pairing listener and sent
    /// its pair request. Valid only while the QR is displayed, unexpired, and
    /// for the displayed identity — anything else is ignored (returns false).
    @discardableResult
    public mutating func pairRequested(candidateName: String, identity: String, now: Date) -> Bool {
        guard case let .displaying(displayed, expiresAt) = phase,
              displayed == identity, now < expiresAt
        else { return false }
        let name = candidateName.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .awaitingApproval(
            candidateName: name.isEmpty ? "A device" : name,
            identity: identity
        )
        return true
    }

    /// The human clicked Approve: returns the device to commit (the ONLY path
    /// that mints one), and the session returns to idle.
    public mutating func approve(now: Date) -> PairedDevice? {
        guard case let .awaitingApproval(candidateName, identity) = phase else { return nil }
        phase = .idle
        return PairedDevice(identity: identity, name: candidateName, addedAt: now)
    }

    /// The human declined, or the pairing sheet was closed: discard the
    /// candidate. Nothing was ever committed (B2).
    public mutating func cancel() {
        phase = .idle
    }
}
