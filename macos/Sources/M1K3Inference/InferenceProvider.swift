//
//  InferenceProvider.swift
//  M1K3Inference
//
//  The one seam every LLM backend implements — Apple Foundation Models (cheap
//  turns), MLX Gemma 3 (the main brain), and the LiteRT Gemma spike all conform.
//  Lifted from the prior call-pipeline's InferenceProvider; chosen over the prior knowledge-server's
//  heavier InferenceService because swap-and-benchmark is the whole point of
//  M1K3's "keep both runtimes open" decision.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.9,
//  Prior: internal call-pipeline project, InferenceProvider (Kev)

import Foundation

public protocol InferenceProvider: Sendable {
    /// Stable identifier for routing, logging, and the runtime picker UI.
    var name: String { get }

    /// Whether this backend is ready to serve right now (model present, OS/
    /// hardware supports it). Cheap and synchronous — the router reads it to
    /// decide ordering without awaiting.
    var isAvailable: Bool { get }

    /// Generate a complete response for `prompt`.
    func generate(prompt: String) async throws -> String

    /// Stream the response incrementally. Yields cumulative-or-delta text
    /// chunks (backend-defined) and finishes when generation completes or the
    /// consumer cancels. Errors terminate the stream rather than throwing.
    func generateStreaming(prompt: String) -> AsyncStream<String>
}

public enum InferenceError: Error, Sendable, Equatable {
    /// The backend failed to produce a response.
    case generationFailed(String)
    /// The backend is not available right now (e.g. Apple Intelligence went
    /// away after a profile switch). Callers must NOT fall back on the same
    /// provider — it will fail identically.
    case providerUnavailable(String)
}
