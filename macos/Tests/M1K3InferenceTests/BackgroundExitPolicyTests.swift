import Foundation
@testable import M1K3Inference
import Testing

/// Leaving the phone app while Lil was mid-answer and coming back killed the app: the answer kept the brain
/// alive through the background shed, and the return loaded a second copy (drilled 2026-11-11).
struct BackgroundExitPolicyTests {
    @Test("an answer being made on this device's GPU is stopped at the background exit")
    func stopsAnOnDeviceTurn() {
        #expect(BackgroundExitPolicy.stopsTurn(turnInFlight: true, brainRunsOnThisDevicesGPU: true))
    }

    @Test("a turn that runs elsewhere holds no weights here and is left alone; no turn, nothing to stop")
    func leavesTheRest() {
        #expect(!BackgroundExitPolicy.stopsTurn(turnInFlight: true, brainRunsOnThisDevicesGPU: false))
        #expect(!BackgroundExitPolicy.stopsTurn(turnInFlight: false, brainRunsOnThisDevicesGPU: true))
        #expect(!BackgroundExitPolicy.stopsTurn(turnInFlight: false, brainRunsOnThisDevicesGPU: false))
    }

    /// The shell is not built by `swift test`, so the wiring is pinned on its source.
    private static let shell = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("M1K3iOSApp")

    @Test("the phone stops the turn and the speech BEFORE it sheds the brain")
    func theExitStopsBeforeItSheds() throws {
        let app = try String(contentsOf: Self.shell.appendingPathComponent("M1K3iOSHarnessApp.swift"), encoding: .utf8)
        let background = try #require(app.range(of: "case .background:"))
        let rest = app[background.upperBound...]
        let stop = try #require(rest.range(of: "core?.stopForBackground()"))
        let shed = try #require(rest.range(of: "core?.releaseForBackground()"))
        #expect(stop.lowerBound < shed.lowerBound)
    }

    @Test("the stop asks the policy, with the brain that is loaded on this device")
    func theStopAsksThePolicy() throws {
        let core = try String(contentsOf: Self.shell.appendingPathComponent("AppCore.swift"), encoding: .utf8)
        let stop = try #require(core.range(of: "func stopForBackground()"))
        let body = core[stop.upperBound...].prefix(900)
        #expect(body.contains("BackgroundExitPolicy.stopsTurn("))
        #expect(body.contains("chat.stopResponding()"))
        #expect(body.contains("stopSpeakingAnswer()"))
    }
}
