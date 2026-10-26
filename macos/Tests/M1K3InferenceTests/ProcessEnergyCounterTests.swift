//
//  ProcessEnergyCounterTests.swift
//  M1K3InferenceTests
//
//  The RUSAGE_INFO_V6 read of this process's own energy counter. What it can
//  and cannot see (CPU yes, GPU no) is measured in docs/ENERGY_MEASUREMENT.md;
//  here only the contract: on macOS the read succeeds unprivileged and the
//  counter never runs backwards. No timing bound and no busy loop — the
//  counter's size is the probe's business, not a unit test's.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.85. Prior: none (new file).

@testable import M1K3Inference
import Testing

struct ProcessEnergyCounterTests {
    #if canImport(Darwin.libproc)
        @Test("on macOS the read succeeds without root and the nanojoule counter never decreases")
        func readsNonDecreasing() throws {
            let first = try #require(ProcessEnergyCounter.read())
            let second = try #require(ProcessEnergyCounter.read())
            #expect(second.energyNJ >= first.energyNJ)
            #expect(second.performanceEnergyNJ >= first.performanceEnergyNJ)
        }
    #else
        @Test("without libproc (iOS, visionOS) there is no reading")
        func noReadingWithoutLibproc() {
            #expect(ProcessEnergyCounter.read() == nil)
        }
    #endif

    @Test("joules between two readings is the nanojoule delta, and a counter reset reads as nil, never negative")
    func joulesBetweenReadings() {
        let before = ProcessEnergyReading(energyNJ: 1_000_000_000, performanceEnergyNJ: 900_000_000, billedEnergy: 7)
        let after = ProcessEnergyReading(energyNJ: 3_500_000_000, performanceEnergyNJ: 3_000_000_000, billedEnergy: 7)
        #expect(after.joules(since: before) == 2.5)
        #expect(before.joules(since: after) == nil)
    }
}
