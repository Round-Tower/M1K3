//
//  MLXMemoryBudgetTests.swift
//  M1K3MLXTests
//
//  Pure policy tests for the process-global MLX memory budget: the RAM→limit
//  mapping that bounds the Metal buffer cache (which otherwise grows to peak
//  and never shrinks — the observed ~16GB-on-an-easy-query bug). The actual
//  MLX.GPU.set calls are verify-by-launch (metallib only resolves in the .app).
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.8, Prior: Unknown
//

import Foundation
@testable import M1K3MLX
import Testing

struct MLXMemoryBudgetTests {
    private func gigabytes(_ count: Double) -> UInt64 {
        UInt64(count * 1_073_741_824)
    }

    @Test("cache limit scales with physical memory in three bands")
    func cacheLimitScalesWithPhysicalMemory() {
        // Below 12GB: smallest cache — every byte matters on fleet minimums.
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(8)).cacheLimitBytes == 32 * 1_048_576)
        // 12GB up to (not including) 32GB.
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(12)).cacheLimitBytes == 64 * 1_048_576)
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(16)).cacheLimitBytes == 64 * 1_048_576)
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(24)).cacheLimitBytes == 64 * 1_048_576)
        // 32GB and above.
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(32)).cacheLimitBytes == 128 * 1_048_576)
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(64)).cacheLimitBytes == 128 * 1_048_576)
    }

    @Test("memory limit is 75% of physical RAM up to the companion ceiling")
    func memoryLimitCappedAtCompanionCeiling() {
        // Small machines: 75% of physical RAM (no cap reached).
        let eight = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(8))
        #expect(eight.memoryLimitBytes == Int(gigabytes(6)))

        let sixteen = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(16))
        #expect(sixteen.memoryLimitBytes == Int(gigabytes(12)))

        // Large machines: capped at the companion ceiling (12 GB).
        let sixtyfour = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(64))
        #expect(sixtyfour.memoryLimitBytes == Int(gigabytes(12)))

        let ninetysix = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(96))
        #expect(ninetysix.memoryLimitBytes == Int(gigabytes(12)))

        let onetwentyeight = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(128))
        #expect(onetwentyeight.memoryLimitBytes == Int(gigabytes(12)))
    }

    @Test("mobile profile caps the memory limit far below the desktop ceiling")
    func mobileProfileUsesLowerCeiling() {
        // iPad Pro / Vision Pro (16GB physical): the desktop path would allow 12GB,
        // but the iOS/visionOS per-app jetsam budget is a fraction of physical RAM —
        // the mobile ceiling (4GB) must win so MLX back-pressure engages BEFORE the
        // OS jetsams the app. A 4-bit 4B brain + KV lives comfortably under it.
        let mobile16 = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(16), profile: .mobile)
        #expect(mobile16.memoryLimitBytes == Int(gigabytes(4)))
        // iPhone (8GB): 75% would be 6GB desktop, still clamped to the 4GB ceiling.
        let mobile8 = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(8), profile: .mobile)
        #expect(mobile8.memoryLimitBytes == Int(gigabytes(4)))
        // Below the ceiling the 75%-of-RAM rule still applies (small device).
        let mobile4 = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(4), profile: .mobile)
        #expect(mobile4.memoryLimitBytes == Int(gigabytes(3)))
        // Desktop is the default and is unchanged (regression guard for the Mac path).
        let desktop16 = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(16))
        #expect(desktop16.memoryLimitBytes == Int(gigabytes(12)))
        let desktop16Explicit = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(16), profile: .desktop)
        #expect(desktop16Explicit.memoryLimitBytes == Int(gigabytes(12)))
    }

    @Test("an operator override raises the desktop ceiling, clamped to 90% of RAM; mobile ignores it")
    func overrideRaisesCeiling() {
        let gb = 1_073_741_824
        // 24 GB on a 64 GB Mac: honoured exactly (above the 12 GB ceiling).
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(64), overrideLimitGB: 24).memoryLimitBytes == 24 * gb)
        // A byte count pasted where a GB count belongs (24 GB written as 25_769_803_776) must clamp to
        // 90% of RAM, never overflow the multiply and trap at the first MLX entry point.
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(64), overrideLimitGB: 25_769_803_776).memoryLimitBytes == 64 * gb / 10 * 9)
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(64), overrideLimitGB: Int.max).memoryLimitBytes == 64 * gb / 10 * 9)
        // 100 GB on a 64 GB Mac: clamped to 90% of physical.
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(64), overrideLimitGB: 100).memoryLimitBytes == Int(gigabytes(64) / 10 * 9))
        // nil / zero / negative: the standard ceiling.
        let standard = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(64)).memoryLimitBytes
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(64), overrideLimitGB: 0).memoryLimitBytes == standard)
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(64), overrideLimitGB: -3).memoryLimitBytes == standard)
        // Mobile never honours it.
        let mobile = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(16), profile: .mobile).memoryLimitBytes
        #expect(MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(16), profile: .mobile, overrideLimitGB: 12).memoryLimitBytes == mobile)
    }

    @Test("the per-tier limit follows the brain that actually loaded: 1.5× its active weights, never below the base, never above 75% of RAM")
    func perTierLimitFollowsLoadedWeights() {
        let gb = 1_073_741_824
        let base64 = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(64)).memoryLimitBytes // 12 GB ceiling
        // Lil (2.2 GB active) on a 64 GB Mac: the companion ceiling already holds it — unchanged.
        #expect(MLXMemoryBudget.limit(accommodatingActiveBytes: Int(2.2 * Double(gb)), physicalMemoryBytes: gigabytes(64)) == base64)
        // Qwen3.8-27B-4bit (~15 GB active) on 64 GB: raised to 1.5× = 22.5 GB (measured 2026-09-05: 24 GB gave 10–16 tok/s,
        // the 12 GB ceiling gave 0.1–0.4).
        let twentyTwoAndAHalf = Int(22.5 * Double(gb))
        #expect(MLXMemoryBudget.limit(accommodatingActiveBytes: 15 * gb, physicalMemoryBytes: gigabytes(64)) == twentyTwoAndAHalf)
        // The same brain on a 16 GB Mac: 1.5× would be 22.5 GB; capped at 75% of RAM = 12 GB = the base. No raise.
        #expect(MLXMemoryBudget.limit(accommodatingActiveBytes: 15 * gb, physicalMemoryBytes: gigabytes(16)) == 12 * gb)
        // On a 32 GB Mac: min(22.5, 24) = 22.5 GB.
        #expect(MLXMemoryBudget.limit(accommodatingActiveBytes: 15 * gb, physicalMemoryBytes: gigabytes(32)) == twentyTwoAndAHalf)
        // An operator override is the floor, never lowered by a small brain.
        #expect(MLXMemoryBudget.limit(accommodatingActiveBytes: 2 * gb, physicalMemoryBytes: gigabytes(64), overrideLimitGB: 24) == 24 * gb)
        // An override ABOVE 75% of RAM stays the floor: the 75% cap bounds the raise, not the operator (52 of 64 GB = 81%).
        #expect(MLXMemoryBudget.limit(accommodatingActiveBytes: 15 * gb, physicalMemoryBytes: gigabytes(64), overrideLimitGB: 52) == 52 * gb)
        // Mobile never raises: the jetsam ceiling is the law there.
        let mobile = MLXMemoryBudget.budget(forPhysicalMemory: gigabytes(16), profile: .mobile).memoryLimitBytes
        #expect(MLXMemoryBudget.limit(accommodatingActiveBytes: 6 * gb, physicalMemoryBytes: gigabytes(16), profile: .mobile) == mobile)
        // Nothing loaded: the base.
        #expect(MLXMemoryBudget.limit(accommodatingActiveBytes: 0, physicalMemoryBytes: gigabytes(64)) == base64)
        // The raise is quantised to 512 MB steps so a few MB of KV wobble between turns never moves the limit
        // (measured 2026-09-05: 14751 → 15003 → 14683 MB active across one eval, the limit re-settled each time).
        let mb = 1_048_576
        let a = MLXMemoryBudget.limit(accommodatingActiveBytes: 14751 * mb, physicalMemoryBytes: gigabytes(64))
        let b = MLXMemoryBudget.limit(accommodatingActiveBytes: 14900 * mb, physicalMemoryBytes: gigabytes(64))
        #expect(a == b)
        #expect(a % (512 * mb) == 0)
        #expect(a >= 14751 * mb / 2 * 3)
    }

    @Test("the per-tier limit never shrinks as the loaded brain grows")
    func perTierLimitIsMonotonicInWeights() {
        let gb = 1_073_741_824
        let samples = stride(from: 0, through: 40, by: 2).map {
            MLXMemoryBudget.limit(accommodatingActiveBytes: $0 * gb, physicalMemoryBytes: gigabytes(64))
        }
        for (smaller, larger) in zip(samples, samples.dropFirst()) {
            #expect(larger >= smaller)
        }
        #expect(samples.last == 48 * gb) // 75% of 64 GB is the hard top
    }

    @Test("budget never shrinks as physical memory grows")
    func budgetIsMonotonic() {
        let samples = stride(from: 4.0, through: 128.0, by: 4.0)
            .map { MLXMemoryBudget.budget(forPhysicalMemory: gigabytes($0)) }
        for (smaller, larger) in zip(samples, samples.dropFirst()) {
            #expect(larger.cacheLimitBytes >= smaller.cacheLimitBytes)
            #expect(larger.memoryLimitBytes >= smaller.memoryLimitBytes)
        }
    }
}
