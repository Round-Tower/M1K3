//
//  PrivateCloudAnsweringTests.swift
//  M1K3LanguageModelTests
//
//  The backend seam's one piece of logic: any error a backend throws maps to a
//  failure the rung can explain — its own typed failure, or `.other`, never a
//  silent empty answer.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.9, Prior: Unknown
//

import Foundation
@testable import M1K3LanguageModel
import Testing

struct PrivateCloudAnsweringTests {
    private struct Unrelated: Error {}

    @Test("a typed failure survives the trip through `any Error`")
    func typedFailureMaps() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let failures: [PrivateCloudFailure] = [
            .rateLimited, .quotaLimitReached(resetsAt: reset), .network, .unavailable, .other,
        ]
        for failure in failures {
            let thrown: any Error = PrivateCloudError(failure)
            #expect(PrivateCloudError.failure(for: thrown) == failure)
        }
    }

    @Test("anything else a backend throws is `.other`")
    func unknownErrorIsOther() {
        #expect(PrivateCloudError.failure(for: Unrelated()) == .other)
        #expect(PrivateCloudError.failure(for: CancellationError()) == .other)
    }
}
