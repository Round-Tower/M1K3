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
}

public extension SystemStatusProviding {
    /// Default unknown — a fake or a platform without the API stays honest.
    func providingPowerSource() -> PowerSource? {
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
