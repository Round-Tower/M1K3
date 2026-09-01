//
//  BatteryStatusTool.swift
//  M1K3AgentTools
//
//  The battery sense — Phase 1 of the context-tools charter
//  (docs/CONTEXT_TOOLS_PLAN.md): a compact health snapshot (charge, state,
//  time estimate, cycle count, condition), never a stream. Exclusion-EXEMPT
//  by charter ("check my battery and search for a cable" must keep working),
//  and consent-gated into the palette by the app (default OFF, absent when
//  off — the withhold pattern, not a refusal).
//
//  A separate seam from SystemStatusProviding on purpose: extending
//  BatterySnapshot would break its memberwise init across tests + the iOS
//  shell, and this tool's snapshot is richer (health, not just charge).
//
//  Signed: Kev + claude-sonnet-5, 2026-09-01, Confidence 0.85 (formatter +
//  tool TDD'd; the live IOKit walk is smoke-tested only — cycle count is
//  deliberately nil in v1, the IOPS dictionary doesn't carry it). Prior:
//  none (new file).
//

import Foundation
import M1K3Agent
import M1K3Inference

#if canImport(IOKit)
    import IOKit.ps
#endif

/// One battery-health observation. `nil` from a provider means no battery
/// at all (a desktop Mac) — a different, honest answer than 0%.
public struct BatteryHealthSnapshot: Sendable, Equatable {
    public let percentage: Int
    public let isCharging: Bool
    /// Minutes to empty (discharging) or to full (charging); nil when the
    /// OS hasn't settled on an estimate.
    public let minutesRemaining: Int?
    public let cycleCount: Int?
    /// The OS's own health word ("Normal", "Good", …), passed through verbatim.
    public let condition: String?

    public init(
        percentage: Int,
        isCharging: Bool,
        minutesRemaining: Int? = nil,
        cycleCount: Int? = nil,
        condition: String? = nil
    ) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.minutesRemaining = minutesRemaining
        self.cycleCount = cycleCount
        self.condition = condition
    }
}

/// The OS seam — fake in tests, IOKit live, nil where there's no battery.
public protocol BatteryHealthProviding: Sendable {
    func healthSnapshot() -> BatteryHealthSnapshot?
}

/// Pure formatting: one compact sentence (plus a health sentence when the
/// provider knows more) — a summary, never a feed (charter rule 2).
public enum BatteryStatusFormatter {
    public static func format(_ snapshot: BatteryHealthSnapshot?) -> String {
        guard let snapshot else { return "No battery — running on mains power." }
        var line = "Battery \(snapshot.percentage)% — "
        line += snapshot.isCharging ? "charging" : "discharging"
        if let minutes = snapshot.minutesRemaining {
            let clock = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
            line += snapshot.isCharging ? ", about \(clock) to full" : ", about \(clock) left"
        }
        line += "."
        var health: [String] = []
        if let cycles = snapshot.cycleCount { health.append("\(cycles) cycles") }
        if let condition = snapshot.condition {
            health.append(health.isEmpty ? "Condition \(condition)" : "condition \(condition)")
        }
        if !health.isEmpty { line += " " + health.joined(separator: ", ") + "." }
        return line
    }
}

public struct BatteryStatusTool: AgentTool {
    public let name = "battery_status"
    public let description =
        "Get \(HostPlatform.thisDevice)'s battery health: charge, charging state, "
            + "time estimate and condition. Argument: optional, ignored."
    public let parameters = [
        ToolParameter(name: "query", description: "ignored"),
    ]

    private let provider: any BatteryHealthProviding

    public init(provider: any BatteryHealthProviding = LiveBatteryHealthProvider()) {
        self.provider = provider
    }

    public func execute(input _: [String: String]) async throws -> ToolResult {
        ToolResult(output: BatteryStatusFormatter.format(provider.healthSnapshot()))
    }
}

/// The IOKit walk (macOS); other platforms honestly report no battery lane.
public struct LiveBatteryHealthProvider: BatteryHealthProviding {
    public init() {}

    public func healthSnapshot() -> BatteryHealthSnapshot? {
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
                let isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
                let minutesKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
                let rawMinutes = info[minutesKey] as? Int
                return BatteryHealthSnapshot(
                    percentage: Int((Double(capacity) / Double(max) * 100).rounded()),
                    isCharging: isCharging,
                    // -1 is IOKit's "still estimating" — honesty over a guess.
                    minutesRemaining: (rawMinutes ?? -1) > 0 ? rawMinutes : nil,
                    cycleCount: nil,
                    condition: info[kIOPSBatteryHealthKey] as? String
                )
            }
            return nil
        #else
            return nil
        #endif
    }
}
