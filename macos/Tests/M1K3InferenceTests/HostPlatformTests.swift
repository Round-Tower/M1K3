//
//  HostPlatformTests.swift
//  M1K3InferenceTests
//
//  Pins the platform-honest device nouns the prompt surface interpolates.
//  On macOS the noun is the vendor-agnostic "machine" (Kev, 2026-08-31 —
//  the brand-named "Mac" read as brand voice, not M1K3's own voice; every
//  call site is prose, so the swap is byte-safe). visionOS/other arms are
//  compile-time (#if os) and can't execute under this suite — their honesty
//  is pinned by inspection + the mobile compile.
//
//  Signed: Kev + claude-fable-5, 2026-08-31, Confidence 0.85 (macOS arm
//  test-pinned exactly; non-mac arms compile-checked by the mobile-build
//  job, not executable here; live voice feel is verify-by-ear).
//  Prior: Kev + claude-fable-5, 2026-07-18 (froze "Mac" — this supersedes it).
//

@testable import M1K3Inference
import Testing

struct HostPlatformTests {
    @Test("macOS uses the vendor-agnostic noun — 'machine' / 'this machine' / 'your machine'")
    func macOSNounsAreAgnostic() {
        #if os(macOS)
            #expect(HostPlatform.noun == "machine")
            #expect(HostPlatform.thisDevice == "this machine")
            #expect(HostPlatform.yourDevice == "your machine")
            // The two determiner phrases the prompt composes from the bare noun.
            #expect("the \(HostPlatform.noun)'ll" == "the machine'll")
            #expect("My \(HostPlatform.noun)'s" == "My machine's")
        #endif
    }

    @Test("the nouns are lowercase noun phrases — safe mid-sentence")
    func nounsComposeMidSentence() {
        #expect(HostPlatform.thisDevice.hasPrefix("this "))
        #expect(HostPlatform.yourDevice.hasPrefix("your "))
        #expect(!HostPlatform.thisDevice.contains("\n"))
        #expect(!HostPlatform.yourDevice.contains("\n"))
    }
}
