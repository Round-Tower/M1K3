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
