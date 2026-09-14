//
//  PrivateCloudBackendsTests.swift
//  M1K3AgentTests
//
//  `PrivateCloudBackends.live()` is the ALWAYS-compiled seam ADR 0006's
//  `#if M1K3_FM27` adapter sits behind (PrivateCloudComputeBackend.swift). These
//  pins run on every toolchain, every CI machine, with no entitlement — which is
//  exactly the point: `live()` must return nil everywhere until three things are
//  simultaneously true (M1K3_FM27 compiled in, macOS 27+, the entitlement), and a
//  plain `swift test` run proves the first is false here by construction.
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
//

import Foundation
@testable import M1K3Agent
import Testing
#if M1K3_FM27
    import FoundationModels
    import M1K3LanguageModel
#endif

struct PrivateCloudBackendsTests {
    /// The load-bearing negative: a build without `M1K3_FM27` (every CI run, every
    /// stable release today) never offers a PCC backend, whatever the OS or
    /// entitlement state — ADR 0006's "absence is silence" applies to the adapter
    /// itself, not just the policy layer above it.
    @Test("live is nil in a test process, with or without M1K3_FM27")
    func liveIsNilWithoutFM27() {
        // Without the flag there is no adapter; with it, this unsigned test
        // process still holds no PCC entitlement. Either way: no backend.
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

#if M1K3_FM27
    /// The adapter's one hand-written SDK mapping, compiled only on the macOS 27
    /// toolchain (`M1K3_FM27=1 DEVELOPER_DIR=/Applications/Xcode-beta.app swift
    /// test --filter PrivateCloudComputeFailureMappingTests`). CI never sets the
    /// flag; this is where a changed SDK error shape shows up first.
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
