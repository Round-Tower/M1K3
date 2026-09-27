//
//  BackendRouting.swift
//  M1K3Inference
//
//  A façade that hands each turn to one backend (SwappableInferenceProvider, the app's
//  RuntimeInferenceProvider). Capability questions — tool calls, token counts — are
//  forwarded capability by capability; this answers the other kind: WHICH brain is
//  serving, for code gated on the brain itself (the Mini-only tool router).
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.9. Prior: none (new file).
//  Why it exists: the router asked with a cast to SwappableInferenceProvider alone, so
//  behind the app's RuntimeInferenceProvider it never ran on the Mac (build 373) while
//  every eval, holding the bare provider, passed. Pinned by `routeSeesThroughFacades`
//  and `routedBackendFollowsSwap`.
//

/// Unwrap in a loop: the app's RuntimeInferenceProvider can hold a
/// SwappableInferenceProvider.
public protocol BackendRouting: Sendable {
    var routedBackend: any InferenceProvider { get }
}
