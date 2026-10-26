//
//  ProcessEnergyCounter.swift
//  M1K3Inference
//
//  This process's own energy counters, read through
//  `proc_pid_rusage(getpid(), RUSAGE_INFO_V6)`: no root, no entitlement, and it
//  reads inside an App Sandbox (measured with a sandboxed probe, 2026-10-26).
//  What it CANNOT see is the point of the docs: `ri_energy_nj` is CPU energy
//  only. A Metal burn that kept the GPU busy 1.94–1.99 s of 2 s moved it
//  0.009–0.045 J (four runs, plain and sandboxed; docs/ENERGY_MEASUREMENT.md),
//  and a Lil answer is about 93 % GPU (POWER_RECEIPT run 1: 34.42 of 37.14 W).
//  So this is an instrument and a future CPU term, never "this answer cost X".
//  `docs/ENERGY_MEASUREMENT.md` has the table.
//
//  Gated on `canImport(Darwin.libproc)`, not `canImport(Darwin)`: the iOS and
//  visionOS SDKs ship `rusage_info_v6` but not `libproc.h`, so the wider gate
//  compiles the call there and fails (`cannot find 'proc_pid_rusage'`).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.85 (the read and the
//  CPU-only verdict are measured on this M1 Max; the in-app read is the
//  M1K3_SELFTEST_ENERGY stage's to prove). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-26 (pre-push review fold) — the header quoted a GPU-burn figure no run
//  contains (1.8 s, 0.02 J); it now quotes the four runs' range, and 93 % (34.42 / 37.14 rounds up). Comment only;
//  the equal-readings boundary of `joules(since:)` is now pinned. Confidence 0.85.

#if canImport(Darwin.libproc)
    import Darwin
#endif

/// One read of the process's energy counters, as the kernel keeps them.
public struct ProcessEnergyReading: Sendable, Equatable {
    /// `ri_energy_nj`: CPU energy billed to this process, nanojoules.
    public let energyNJ: UInt64
    /// `ri_penergy_nj`: the performance-core share of `energyNJ`, nanojoules.
    public let performanceEnergyNJ: UInt64
    /// `ri_billed_energy`: energy other processes did on this one's behalf.
    /// It did not move with either a CPU or a GPU burn in the 2026-10-26 probe.
    public let billedEnergy: UInt64

    public init(energyNJ: UInt64, performanceEnergyNJ: UInt64, billedEnergy: UInt64) {
        self.energyNJ = energyNJ
        self.performanceEnergyNJ = performanceEnergyNJ
        self.billedEnergy = billedEnergy
    }

    /// CPU joules since `earlier`, or nil when the counter went backwards
    /// (a different process's reading, or a reset) — never a negative figure.
    public func joules(since earlier: ProcessEnergyReading) -> Double? {
        guard energyNJ >= earlier.energyNJ else { return nil }
        return Double(energyNJ - earlier.energyNJ) / 1_000_000_000
    }
}

public enum ProcessEnergyCounter {
    /// This process's counters now; nil where libproc is absent or the call fails.
    public static func read() -> ProcessEnergyReading? {
        #if canImport(Darwin.libproc)
            var info = rusage_info_v6()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V6, rebound)
                }
            }
            guard result == 0 else { return nil }
            return ProcessEnergyReading(
                energyNJ: info.ri_energy_nj,
                performanceEnergyNJ: info.ri_penergy_nj,
                billedEnergy: info.ri_billed_energy
            )
        #else
            return nil
        #endif
    }
}
