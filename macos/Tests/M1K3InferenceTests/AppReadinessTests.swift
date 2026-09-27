//
//  AppReadinessTests.swift
//  M1K3InferenceTests
//
//  Pins the global "is the app usable yet" resolution. The bug it guards: an MLX
//  brain's `isAvailable` is hard-coded `true` (the backend CAN serve) even before
//  its ~3GB weights are on disk, so the app looked ready and let a turn fire that
//  then stalled on a silent lazy download. Readiness for a weight-backed brain must
//  hang on the load state reaching `.ready`, not on the backend's availability.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-09-27 — `instantSettling`: AFM getting ready (the
//  transient `.modelNotReady`) waits as loading instead of the "can't run here" dead end.

@testable import M1K3Inference
import Testing

struct AppReadinessTests {
    // MARK: - Instant backend (Apple Foundation Models — no weights to fetch)

    @Test("instant backend is ready as soon as it is available")
    func instantReady() {
        let result = ModelReadiness.resolve(requiresWeights: false, load: .idle, backendAvailable: true)
        #expect(result == .ready)
        #expect(result.isReady)
    }

    @Test("instant backend is unavailable when the system model can't serve")
    func instantUnavailable() {
        let result = ModelReadiness.resolve(requiresWeights: false, load: .idle, backendAvailable: false)
        #expect(result == .unavailable)
        #expect(!result.isReady)
    }

    /// 2026-09-27: after three quick Mini turns AFM reported "not ready" (the daemon's
    /// transient `.modelNotReady`) and the Mac put up "This Mac can't run the selected
    /// brain", with a Switch to Lil button. Getting ready is a wait, never a dead end;
    /// a hard block still is.
    @Test("instant backend that is getting ready waits instead of dead-ending")
    func instantSettling() {
        let result = ModelReadiness.resolve(
            requiresWeights: false, load: .idle, backendAvailable: false, backendSettling: true
        )
        #expect(result == .loading(.preparing))
        #expect(ModelReadiness.resolve(
            requiresWeights: false, load: .idle, backendAvailable: true, backendSettling: true
        ) == .ready)
        // Weights decide for an MLX brain; settling says nothing about them.
        #expect(ModelReadiness.resolve(
            requiresWeights: true, load: .idle, backendAvailable: false, backendSettling: true
        ) == .loading(.idle))
    }

    @Test("instant backend surfaces an active load as loading (defensive: it normally never downloads)")
    func instantLoading() {
        let result = ModelReadiness.resolve(requiresWeights: false, load: .preparing, backendAvailable: true)
        #expect(result == .loading(.preparing))
        #expect(!result.isReady)
    }

    // MARK: - Weight-backed backend (MLX — must download + load first)

    @Test("weight-backed backend is NOT ready until the load reaches .ready, even when the backend reports available")
    func weightsNotReadyWhileIdle() {
        // The exact bug: MLX.isAvailable == true, but weights aren't loaded.
        let result = ModelReadiness.resolve(requiresWeights: true, load: .idle, backendAvailable: true)
        #expect(result == .loading(.idle))
        #expect(!result.isReady)
    }

    @Test("weight-backed backend surfaces download progress as loading")
    func weightsDownloading() {
        let result = ModelReadiness.resolve(requiresWeights: true, load: .progress(0.42), backendAvailable: true)
        #expect(result == .loading(.downloading(fraction: 0.42)))
        #expect(!result.isReady)
    }

    @Test("weight-backed backend shows preparing as loading")
    func weightsPreparing() {
        #expect(ModelReadiness.resolve(requiresWeights: true, load: .preparing, backendAvailable: true)
            == .loading(.preparing))
    }

    @Test("weight-backed backend is ready once loaded")
    func weightsReady() {
        let result = ModelReadiness.resolve(requiresWeights: true, load: .ready, backendAvailable: true)
        #expect(result == .ready)
        #expect(result.isReady)
    }

    @Test("weight-backed backend ignores backendAvailable — only the load state ungates")
    func weightsIgnoreAvailability() {
        // Documents the deliberate dead-parameter path: for a weight-backed brain the
        // backend's own availability is never consulted (MLX reports `true` by
        // construction), so even backendAvailable=false stays `.loading` until the
        // weights reach `.ready`. Guards against a future "treat unavailable as
        // .unavailable here" refactor sneaking in silently.
        #expect(ModelReadiness.resolve(requiresWeights: true, load: .idle, backendAvailable: false)
            == .loading(.idle))
        #expect(ModelReadiness.resolve(requiresWeights: true, load: .ready, backendAvailable: false)
            == .ready)
    }

    // MARK: - Failure is global, regardless of backend kind

    @Test("a failed load is surfaced with its message for either backend kind")
    func failedSurfaced() {
        #expect(ModelReadiness.resolve(requiresWeights: true, load: .failed(message: "no disk"), backendAvailable: true)
            == .failed("no disk"))
        #expect(ModelReadiness.resolve(requiresWeights: false, load: .failed(message: "boom"), backendAvailable: true)
            == .failed("boom"))
    }
}
