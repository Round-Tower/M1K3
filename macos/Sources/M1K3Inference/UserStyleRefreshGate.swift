//
//  UserStyleRefreshGate.swift
//  M1K3Inference
//
//  The stated style (#699) is re-read from two places that can overlap: an edit or forget
//  in the Memories list on the main actor, and the distiller's didWrite hook off it. Each
//  refresh is a read and then a set, so a read that started first could land last and
//  bring back an ask the user had just forgotten (#730 audit, 2026-10-28). A refresh takes
//  a ticket before it reads, and only a newer ticket than the last applied one may set.
//  Every write's own refresh starts after that write commits, so the newest ticket always
//  read the newest state. A read never runs under the lock, so a prompt build never waits
//  on the store.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-28, Confidence 0.85 (pure, pinned in
//  UserStyleRefreshGateTests with the interleaving that lost a forget), Prior: none (new file)
//

import Synchronization

public final class UserStyleRefreshGate: Sendable {
    private let tickets = Mutex<(issued: UInt64, applied: UInt64)>((0, 0))

    public init() {}

    /// Read, then apply unless a newer refresh already applied. A failed read applies
    /// nothing, so the style already in place stays. True when this refresh applied.
    @discardableResult
    public func refresh(read: () throws -> [String], apply: ([String]) -> Void) -> Bool {
        let ticket = tickets.withLock { state -> UInt64 in
            state.issued += 1
            return state.issued
        }
        guard let texts = try? read() else { return false }
        return tickets.withLock { state in
            guard ticket > state.applied else { return false }
            state.applied = ticket
            apply(texts)
            return true
        }
    }
}
