//
//  PrivateCloudAnswering.swift
//  M1K3LanguageModel
//
//  The seam a Private Cloud Compute backend sits behind (ADR 0006). The real
//  backend wraps `PrivateCloudComputeLanguageModel` and needs the macOS 27 SDK
//  and the `com.apple.developer.private-cloud-compute` entitlement, so it lives
//  behind `#if canImport(FoundationModels)` in M1K3Agent. Everything above this
//  seam — the policy, the consent sheet, the send path, the label — builds and
//  tests on any toolchain against fakes.
//
//  The seam takes two strings and no tools, on purpose: a PCC turn gets the
//  instructions and the prompt `PrivateCloudTurn.request` built from what the
//  user ticked, and nothing else. A backend that wanted more would have to
//  change this signature, in review.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85 (the shape is read
//  from the 27A5194q swiftinterface; the live adapter is verify-owed until the
//  entitlement). Prior: Unknown
//

import Foundation

/// What a backend reports before a send: can it answer, and is the quota left.
public struct PrivateCloudStatus: Sendable, Equatable {
    public let available: Bool
    public let quota: PrivateCloudQuota

    public init(available: Bool, quota: PrivateCloudQuota) {
        self.available = available
        self.quota = quota
    }
}

/// A backend failed in a way the rung acts on. Anything a backend throws that
/// isn't this is treated as `.other`.
public struct PrivateCloudError: Error, Sendable, Equatable {
    public let failure: PrivateCloudFailure

    public init(_ failure: PrivateCloudFailure) {
        self.failure = failure
    }

    /// The failure for any error a backend threw.
    public static func failure(for error: any Error) -> PrivateCloudFailure {
        (error as? PrivateCloudError)?.failure ?? .other
    }
}

public protocol PrivateCloudAnswering: Sendable {
    func status() async -> PrivateCloudStatus
    /// Streams CUMULATIVE snapshots of the answer (FoundationModels' shape).
    /// Throws `PrivateCloudError` for the failures the rung explains.
    func answer(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error>
}
