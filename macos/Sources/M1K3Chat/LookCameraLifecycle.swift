//
//  LookCameraLifecycle.swift
//  M1K3Chat
//
//  When the look's camera is on (#768), as rules `swift test` can hold. The
//  capture itself is the shell's (M1K3iOSApp/LookCamera.swift); this type owns
//  only the order of things, behind four closures: is there a camera, ask for
//  permission, start the session, stop it.
//
//  The promise: the camera is running only while the newest open still stands.
//  An open has two awaits (the permission ask, which can sit behind a system
//  sheet for as long as the user likes, and the session start), and a close
//  can land in either:
//    - in the ask: the open ends there and the session never starts;
//    - in the start: the close's stop may reach the worker BEFORE the start it
//      was meant to undo (the start hops off the main actor first), so the
//      overtaken open stops the worker again when it comes back, unless a
//      newer open now owns it.
//  An open after a close never joins the overtaken one.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.85 (gated-fake
//  tests, LookCameraLifecycleTests), Prior: the rules lived inline in
//  LookCamera (184ebde0), where both pre-push reviews found the race: a close
//  during the permission ask left the camera on with no screen.
//

import Foundation
import Observation

@MainActor
@Observable
public final class LookCameraLifecycle {
    public enum State: Equatable, Sendable {
        case closed, opening, open, denied, restricted, unavailable
    }

    public enum Access: Sendable {
        case granted, denied, restricted
    }

    public private(set) var state: State = .closed

    /// Frames are flowing.
    public var isOpen: Bool {
        state == .open
    }

    /// On, or on its way: what a toggle reads, so a second tap during the
    /// permission ask closes instead of opening twice.
    public var isOn: Bool {
        state == .open || state == .opening
    }

    @ObservationIgnored private let hasCamera: @MainActor () -> Bool
    @ObservationIgnored private let access: @Sendable () async -> Access
    @ObservationIgnored private let start: @Sendable () async -> Bool
    @ObservationIgnored private let stop: @Sendable () -> Void

    /// Bumped by every close: an open that finds it moved was overtaken.
    @ObservationIgnored private var generation = 0
    /// The open in flight, with the generation it belongs to.
    @ObservationIgnored private var opening: (generation: Int, task: Task<Bool, Never>)?

    public init(
        hasCamera: @escaping @MainActor () -> Bool,
        access: @escaping @Sendable () async -> Access,
        start: @escaping @Sendable () async -> Bool,
        stop: @escaping @Sendable () -> Void
    ) {
        self.hasCamera = hasCamera
        self.access = access
        self.start = start
        self.stop = stop
    }

    /// Turn the camera on, asking for permission the first time. True once the
    /// session runs. Two callers at once share one start.
    public func open() async -> Bool {
        if state == .open { return true }
        if let opening { return await opening.task.value }
        let mine = generation
        let task = Task { await self.run(mine) }
        opening = (mine, task)
        let result = await task.value
        // A close cleared the slot and a newer open may hold it now: only
        // this open's own entry is this open's to clear.
        if opening?.generation == mine { opening = nil }
        return result
    }

    /// Turn the camera off. Whatever open is in flight is overtaken: it ends
    /// false, and the next open starts afresh.
    public func close() {
        generation += 1
        opening = nil
        stop()
        if isOn { state = .closed }
    }

    private func run(_ mine: Int) async -> Bool {
        guard hasCamera() else {
            state = .unavailable
            return false
        }
        state = .opening
        let answer = await access()
        // Closed while the permission sheet was up: the session never starts.
        guard mine == generation else { return false }
        switch answer {
        case .granted: break
        case .denied: return end(.denied)
        case .restricted: return end(.restricted)
        }
        let running = await start()
        guard mine == generation else {
            // The close's stop may have reached the worker before this start
            // did. Stop it again, unless a newer open owns the worker now
            // (that open ends running or stops it itself).
            if opening == nil { stop() }
            return false
        }
        guard running else { return end(.unavailable) }
        state = .open
        return true
    }

    /// An open that still stands but did not end running: say why, and make
    /// sure nothing an overtaken start left behind is still on.
    private func end(_ reason: State) -> Bool {
        stop()
        state = reason
        return false
    }
}
