//
//  BatteryStatusToolTests.swift
//  M1K3AgentToolsTests
//
//  The battery sense (context-tools charter, Phase 1): pure formatter pins +
//  the tool over a fake provider. Exclusion-exempt by charter — pinned here.
//
//  Signed: Kev + claude-sonnet-5, 2026-09-01, Confidence 0.85 (red-first
//  against the charter's shape; the live IOKit provider is smoke-only).
//  Prior: none (new file).
//

@testable import M1K3AgentTools
import Testing

struct BatteryStatusFormatterTests {
    @Test("no battery reads as mains power")
    func mainsPower() {
        #expect(BatteryStatusFormatter.format(nil) == "No battery — running on mains power.")
    }

    @Test("bare snapshot: charge and state only")
    func bareSnapshot() {
        let snapshot = BatteryHealthSnapshot(percentage: 84, isCharging: false)
        #expect(BatteryStatusFormatter.format(snapshot) == "Battery 84% — discharging.")
    }

    @Test("discharging with a time estimate")
    func dischargingEstimate() {
        let snapshot = BatteryHealthSnapshot(percentage: 84, isCharging: false, minutesRemaining: 130)
        #expect(BatteryStatusFormatter.format(snapshot)
            == "Battery 84% — discharging, about 2h 10m left.")
    }

    @Test("charging estimates time to full, minutes only under an hour")
    func chargingEstimate() {
        let snapshot = BatteryHealthSnapshot(percentage: 62, isCharging: true, minutesRemaining: 45)
        #expect(BatteryStatusFormatter.format(snapshot)
            == "Battery 62% — charging, about 45m to full.")
    }

    @Test("cycle count and condition append as a second sentence")
    func healthDetail() {
        let snapshot = BatteryHealthSnapshot(
            percentage: 84, isCharging: false, minutesRemaining: 130,
            cycleCount: 312, condition: "Normal"
        )
        #expect(BatteryStatusFormatter.format(snapshot)
            == "Battery 84% — discharging, about 2h 10m left. 312 cycles, condition Normal.")
    }

    @Test("condition alone still gets the second sentence")
    func conditionOnly() {
        let snapshot = BatteryHealthSnapshot(percentage: 90, isCharging: true, condition: "Good")
        #expect(BatteryStatusFormatter.format(snapshot) == "Battery 90% — charging. Condition Good.")
    }
}

struct BatteryStatusToolTests {
    private struct FakeProvider: BatteryHealthProviding {
        let snapshot: BatteryHealthSnapshot?
        func healthSnapshot() -> BatteryHealthSnapshot? {
            snapshot
        }
    }

    @Test("reports the provider's snapshot")
    func reportsSnapshot() async throws {
        let tool = BatteryStatusTool(provider: FakeProvider(
            snapshot: BatteryHealthSnapshot(percentage: 84, isCharging: false)
        ))
        let result = try await tool.execute(input: [:])
        #expect(result.output == "Battery 84% — discharging.")
    }

    @Test("battery is exclusion-exempt by charter")
    func exclusionExempt() {
        #expect(BatteryStatusTool(provider: FakeProvider(snapshot: nil)).exclusionClass == nil)
    }

    @Test("live provider smoke: never crashes, snapshot is sane when present")
    func liveProviderSmoke() {
        if let snapshot = LiveBatteryHealthProvider().healthSnapshot() {
            #expect((0 ... 100).contains(snapshot.percentage))
        }
    }
}
