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

@testable import M1K3Agent
import Testing

struct PrivateCloudBackendsTests {
    /// The load-bearing negative: a build without `M1K3_FM27` (every CI run, every
    /// stable release today) never offers a PCC backend, whatever the OS or
    /// entitlement state — ADR 0006's "absence is silence" applies to the adapter
    /// itself, not just the policy layer above it.
    @Test("live is nil without the M1K3_FM27 compile flag")
    func liveIsNilWithoutFM27() {
        #if M1K3_FM27
        // This build compiled the real adapter in — the compile-gate assertion
        // above doesn't apply. Assert nothing here rather than fail a build that
        // legitimately carries the flag (the FM27 toolchain build, not `swift test`).
        #else
            #expect(PrivateCloudBackends.live() == nil)
        #endif
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
