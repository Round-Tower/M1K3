//
//  VisionPressureRelease.swift
//  M1K3MLX
//
//  Frees the embedder's vision tower when the system reports memory pressure (#836). One watcher per owner:
//  it holds its target WEAKLY (a service that is gone, or an embedder that was replaced, is not kept alive by
//  it), always points at the LATEST target, and cancels its dispatch source when it is released. `fire()` is
//  the seam tests (and the source's handler) use, so the policy is unit-tested without a real pressure event.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.8. Prior: none (new file; #836 review fold).
//  Open: no cooldown, so a machine that stays under pressure drops and reloads the tower per image (~0.3 s each).

import Foundation

/// Something that holds a droppable vision tower.
protocol VisionUnloadable: AnyObject, Sendable {
    func unloadVision() async
}

extension EmbeddingGemma2Embedder: VisionUnloadable {}

final class VisionPressureRelease: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: (any VisionUnloadable)?
    private var source: DispatchSourceMemoryPressure?
    private let onRelease: @Sendable () -> Void

    /// - Parameter onRelease: runs after the target has been told to drop its tower (the service reclaims MLX's
    ///   buffer cache there).
    init(onRelease: @escaping @Sendable () -> Void = {}) {
        self.onRelease = onRelease
    }

    deinit {
        source?.cancel()
    }

    /// Points the watcher at `target` (replacing any earlier one) and installs the system source the first time.
    /// Call it BEFORE the work that can load the tower, so a throw after the load is still covered.
    func watch(_ target: any VisionUnloadable) {
        lock.lock()
        defer { lock.unlock() }
        self.target = target
        guard source == nil else { return }
        let new = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        new.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.fire() }
        }
        new.resume()
        source = new
    }

    /// Drops the current target's tower now.
    func fire() async {
        guard let current = current else { return }
        await current.unloadVision()
        onRelease()
    }

    /// The target the next `fire()` would unload (for tests and `MLXEmbeddingService.unloadVision`).
    var current: (any VisionUnloadable)? {
        lock.lock()
        defer { lock.unlock() }
        return target
    }
}
