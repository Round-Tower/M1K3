//
//  AgentLogStamping.swift
//  M1K3MCPKit
//
//  Client identity for the opt-in Agent Interaction Log: the HTTP shell
//  reports each initialize's self-declared client name into a shared box, and
//  a stamping sink copies the current identity onto every recorded call on its
//  way to the store. The registry itself stays identity-blind (it doesn't know
//  sessions); the transport, which does, never touches the store. This pair is
//  the seam between them.
//
//  The name is UNTRUSTED display data — any process can claim any name in its
//  initialize. It folds the timeline's "visits"; it authorizes nothing.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.9 (pure, TDD'd).
//  Prior: none (new file).
//

import Foundation

/// Thread-safe holder for the CURRENT session's client name. One MCP client
/// at a time (the v1 session model), so one slot: every initialize overwrites,
/// including with nil, so a stale identity can't outlive its session.
public final class ClientIdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?

    public init() {}

    public func set(_ newName: String?) {
        lock.withLock { name = newName }
    }

    public func current() -> String? {
        lock.withLock { name }
    }
}

/// Forwards every recorded call to `base` with the current client identity
/// stamped on, then fires `onRecord` — the host's observable-revision bump so
/// live surfaces re-read without a manual Refresh.
///
/// `isCapturing` mirrors the base store's own opt-in gate: when the Agent
/// Interaction Log is OFF the base no-ops, so bumping the revision would wake
/// every open surface for a read that finds nothing. Pass the SAME predicate
/// the store gates on; the default keeps notify-always for bases that always
/// write (PR #137 review fold).
public struct StampingLogSink: MCPCallLogSink {
    private let base: any MCPCallLogSink
    private let clientName: @Sendable () -> String?
    private let isCapturing: @Sendable () -> Bool
    private let onRecord: @Sendable () -> Void

    public init(
        base: any MCPCallLogSink,
        clientName: @escaping @Sendable () -> String?,
        isCapturing: @escaping @Sendable () -> Bool = { true },
        onRecord: @escaping @Sendable () -> Void = {}
    ) {
        self.base = base
        self.clientName = clientName
        self.isCapturing = isCapturing
        self.onRecord = onRecord
    }

    public func record(_ entry: MCPCallLogEntry) {
        base.record(entry.stamped(clientName: clientName()))
        if isCapturing() { onRecord() }
    }
}
