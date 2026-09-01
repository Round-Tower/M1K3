//
//  HostPlatform.swift
//  M1K3Inference
//
//  Platform-honest device nouns for the prompt surface. Mini introduced itself
//  with "I, M1K3, am running directly on this Mac" ON AN IPHONE (caught
//  on-simulator, 2026-07-18) — every persona/tool string that names the machine
//  now interpolates these instead of hardcoding a literal.
//
//  macOS says "machine", not "Mac" (Kev, 2026-08-31) — the brand name read as
//  brand voice, not M1K3's own; every call site is prose, so the swap is
//  byte-safe (pinned by HostPlatformTests). Compile-time #if — no runtime
//  branching, no UIKit dependency (why iOS says "device", not iPhone/iPad-by-idiom).
//
//  Signed: Kev + claude-fable-5, 2026-08-31, Confidence 0.85 (macOS arm
//  test-pinned exactly; mobile arms compile-proven, honesty-by-inspection;
//  live voice feel is verify-by-ear). Prior: Kev + claude-fable-5, 2026-07-18
//  (froze "Mac" — this session supersedes that freeze on Kev's word).
//

public enum HostPlatform {
    /// The bare device noun — compose it with any determiner the sentence
    /// needs ("the \(noun)'ll keep", "My \(noun)'s gone properly warm").
    public static let noun: String = {
        #if os(macOS)
            return "machine"
        #elseif os(visionOS)
            return "Vision Pro"
        #else
            return "device"
        #endif
    }()

    /// "…running entirely on this machine." — the subject form.
    public static let thisDevice = "this \(noun)"

    /// "…just me and your machine…" — the possessive form.
    public static let yourDevice = "your \(noun)"
}
