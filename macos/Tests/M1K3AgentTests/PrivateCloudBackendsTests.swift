//
//  PrivateCloudBackendsTests.swift
//  M1K3AgentTests
//
//  `PrivateCloudBackends.live()` is the ALWAYS-compiled seam ADR 0006's
//  FoundationModels adapter sits behind (PrivateCloudComputeBackend.swift). These
//  pins run on every toolchain, every CI machine, with no entitlement — which is
//  exactly the point: `live()` must return nil everywhere until three things are
//  simultaneously true (FoundationModels SDK, macOS 27+, the entitlement), and a
//  plain `swift test` run proves the last is false here by construction.
//
//  Signed: Kev + claude-sonnet-5 (apple-specialist agent; directed + reviewed by
//  claude-opus-5), 2026-09-14, Confidence 0.85 (the negative-path
//  pins are exercised on every CI run; the FM27-compiled backend itself is
//  verify-owed until the real 27 toolchain + entitlement). Prior: Unknown
//
//  Review: Kev + claude-opus-5, 2026-09-14 (later) — the test target now gets
//  the M1K3_FM27 define too (it never did, so the FM27 branches here could not
//  compile even on the 27 toolchain), and the SDK-error mapping is pinned under
//  it: PCC's three errors and the unified rate limit, built from the SDK's
//  public initialisers. Under FM27 `live()` is still nil in a test process (no
//  entitlement), so the negative pin now asserts on both toolchains.
//  Confidence now 0.85.
//  Review: Kev + claude-opus-4-6, 2026-09-16 — M1K3_FM27 env-var gate removed;
//  now #if canImport(FoundationModels). The FM27 tests always compile on
//  Xcode 27; @available handles the runtime. Confidence now 0.85.
//

import Foundation
@testable import M1K3Agent
import Testing
#if compiler(>=6.4)
    import FoundationModels
    import M1K3LanguageModel
#endif

struct PrivateCloudBackendsTests {
    /// The load-bearing negative: this unsigned test process holds no PCC
    /// entitlement, so `live()` is nil regardless of the SDK or OS version.
    @Test("live is nil in a test process")
    func liveIsNilInTestProcess() {
        #expect(PrivateCloudBackends.live() == nil)
    }

    /// The test process (`swift test`, unsigned, no entitlements) never reads the
    /// PCC entitlement as present. This is the pin that would catch a future
    /// refactor that defaults `processHasEntitlement()` to true, or reads the
    /// wrong key, without needing Apple's grant to exercise it.
    @Test("the test process does not carry the PCC entitlement")
    func processHasNoEntitlement() {
        #expect(PrivateCloudBackends.processHasEntitlement() == false)
    }
}

#if compiler(>=6.4)
    /// The adapter's SDK mapping, always compiled on Xcode 27+. Runtime-gated
    /// on @available(macOS 27, *) so the tests only run on Golden Gate.
    struct PrivateCloudComputeFailureMappingTests {
        @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
        @Test("PCC's own errors map onto the rung's failure words")
        func pccErrorsMap() {
            typealias PCCError = PrivateCloudComputeLanguageModel.Error
            let reset = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(PrivateCloudComputeBackend.failure(for: PCCError.networkFailure(.init(debugDescription: "x")))
                == .network)
            #expect(PrivateCloudComputeBackend.failure(
                for: PCCError.quotaLimitReached(.init(resetDate: reset, debugDescription: "x"))
            ) == .quotaLimitReached(resetsAt: reset))
            #expect(PrivateCloudComputeBackend.failure(for: PCCError.serviceUnavailable(.init(debugDescription: "x")))
                == .unavailable)
        }

        @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
        @Test("the unified rate limit is a rate limit; anything else is .other")
        func otherErrorsMap() {
            let limited = LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "x"))
            #expect(PrivateCloudComputeBackend.failure(for: limited) == .rateLimited)
            #expect(PrivateCloudComputeBackend.failure(for: CancellationError()) == .other)
        }
    }
#endif
