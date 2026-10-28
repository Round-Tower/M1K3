//
//  SystemStatusProviding.swift
//  M1K3AgentTools
//
//  The OS seam behind SystemStatusTool. Snapshots are pure values; the live
//  provider is the only code touching IOKit/FileManager/ProcessInfo, kept
//  thin and covered by a smoke test (values aren't deterministic).
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.8, Prior: Unknown
//
//  Review: Kev + claude-fable-5.1, 2026-09-10 — `providingPowerSource()` joins the seam (#217): the eval
//  harness read IOKit's providing source as untested app-target glue; one IOKit power idiom now, the
//  string→case mapping pinned. Confidence now 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-28 — RAM and CPU load join the seam: the tool menu promised "CPU,
//  memory or disk" and the tool had neither. Mach VM stats (Activity Monitor's "Memory Used") and getloadavg;
//  both nil when the kernel won't say, and fakes inherit nil. Confidence 0.8 (the live values are smoke only).

import Foundation

// IOKit is macOS-only. The battery lane is the ONLY IOKit user; guarding the
// import (rather than the whole file) keeps the disk/uptime lanes — and every
// pure snapshot type — portable to iOS/visionOS for the shared shell. macOS
// compiles the exact same code as before (byte-identical behaviour).
#if canImport(IOKit)
    import IOKit.ps
#endif

public struct BatterySnapshot: Sendable, Equatable {
    public let percentage: Int
    public let isCharging: Bool

    public init(percentage: Int, isCharging: Bool) {
        self.percentage = percentage
        self.isCharging = isCharging
    }
}

public struct DiskSnapshot: Sendable, Equatable {
    public let availableBytes: Int64
    public let totalBytes: Int64

    public init(availableBytes: Int64, totalBytes: Int64) {
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }
}

/// Physical memory in use, counted as Activity Monitor's "Memory Used": app memory
/// (anonymous pages less purgeable ones), wired and compressed.
public struct RAMSnapshot: Sendable, Equatable {
    public let usedBytes: Int64
    public let totalBytes: Int64

    public init(usedBytes: Int64, totalBytes: Int64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }
}

/// The one-minute load average and the cores it is spread over.
public struct CPULoadSnapshot: Sendable, Equatable {
    public let oneMinuteLoad: Double
    public let cores: Int

    public init(oneMinuteLoad: Double, cores: Int) {
        self.oneMinuteLoad = oneMinuteLoad
        self.cores = cores
    }
}

/// What is powering the machine right now — the field that catches a tok/s
/// day measured on battery under Adaptive Power (2026-09-05: `pmset` said
/// powermode 0, the decode doubled once plugged in). Raw values are the eval
/// provenance vocabulary (`EvalProvenance.powerSource`).
public enum PowerSource: String, Sendable, Equatable {
    case ac, battery, ups

    /// IOKit's `IOPSGetProvidingPowerSourceType` literals ("AC Power",
    /// "Battery Power", "UPS Power"); anything else ("Off Line", empty) is nil.
    public init?(iokitProvidingType type: String) {
        switch type {
        case "AC Power": self = .ac
        case "Battery Power": self = .battery
        case "UPS Power": self = .ups
        default: return nil
        }
    }
}

public protocol SystemStatusProviding: Sendable {
    /// nil on a Mac with no battery (desktop).
    func batterySnapshot() -> BatterySnapshot?
    func diskSnapshot() throws -> DiskSnapshot
    func uptime() -> TimeInterval
    /// nil when the provider cannot tell (no IOKit, off-line).
    func providingPowerSource() -> PowerSource?
    /// nil when the kernel won't say.
    func ramSnapshot() -> RAMSnapshot?
    /// nil when the kernel won't say.
    func cpuLoad() -> CPULoadSnapshot?
}

public extension SystemStatusProviding {
    /// Default unknown — a fake or a platform without the API stays honest.
    func providingPowerSource() -> PowerSource? {
        nil
    }

    func ramSnapshot() -> RAMSnapshot? {
        nil
    }

    func cpuLoad() -> CPULoadSnapshot? {
        nil
    }
}

public struct LiveSystemStatusProvider: SystemStatusProviding {
    public init() {}

    public func batterySnapshot() -> BatterySnapshot? {
        #if canImport(IOKit)
            guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
            else { return nil }

            for source in sources {
                guard let info = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                    let capacity = info[kIOPSCurrentCapacityKey] as? Int,
                    let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
                else { continue }
                let charging = (info[kIOPSIsChargingKey] as? Bool) ?? false
                return BatterySnapshot(percentage: capacity * 100 / max, isCharging: charging)
            }
            return nil
        #else
            // iOS/visionOS: no IOKit power-sources API. Battery is optional (nil on a
            // desktop Mac too), so the tool degrades cleanly. A UIDevice-based lane is
            // a Phase-B follow — it needs MainActor hops this nonisolated seam avoids.
            return nil
        #endif
    }

    public func diskSnapshot() throws -> DiskSnapshot {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ])
        return DiskSnapshot(
            availableBytes: values.volumeAvailableCapacityForImportantUsage ?? 0,
            totalBytes: Int64(values.volumeTotalCapacity ?? 0)
        )
    }

    public func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// `host_statistics64`, which the sandbox allows on every platform.
    public func ramSnapshot() -> RAMSnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let anonymous = UInt64(stats.internal_page_count)
        let appPages = anonymous - min(UInt64(stats.purgeable_count), anonymous)
        let pages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        return RAMSnapshot(usedBytes: min(Int64(pages) * Int64(pageSize), total), totalBytes: total)
    }

    public func cpuLoad() -> CPULoadSnapshot? {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) >= 1 else { return nil }
        return CPULoadSnapshot(oneMinuteLoad: load[0], cores: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Copy-rule → takeRetained, Get-rule → takeUnretained (the over-release
    /// review 1 on #216 caught lives on in this one idiom).
    public func providingPowerSource() -> PowerSource? {
        #if canImport(IOKit)
            guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
            else { return nil }
            return PowerSource(iokitProvidingType: type)
        #else
            return nil
        #endif
    }
}
