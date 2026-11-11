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
        #expect(app.components(separatedBy: "case .background:").count == 2, "one background case in the shell")
        let background = try #require(app.range(of: "case .background:"))
        let rest = app[background.upperBound...]
        let stop = try #require(rest.range(of: "core?.stopForBackground()"))
        let shed = try #require(rest.range(of: "core?.releaseForBackground()"))
        #expect(stop.lowerBound < shed.lowerBound)
    }

    /// The text of one function in the shell, from its declaration to the next one.
    private func body(of declaration: String, in file: String) throws -> Substring {
        let source = try String(contentsOf: Self.shell.appendingPathComponent(file), encoding: .utf8)
        let start = try #require(source.range(of: declaration))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        return Substring(String(rest[..<end]))
    }

    @Test("the stop asks the policy, with the brain that is loaded on this device")
    func theStopAsksThePolicy() throws {
        let body = try body(of: "func stopForBackground()", in: "AppCore.swift")
        #expect(body.contains("BackgroundExitPolicy.stopsTurn("))
        #expect(body.contains("chat.stopResponding()"))
        #expect(body.contains("stopSpeakingAnswer()"))
    }

    @Test("a brain still in memory on the return is taken back, never loaded a second time")
    func theReturnNeverLoadsBesideALiveBrain() throws {
        #expect(BackgroundExitPolicy.onReturn(shedBrainStillLoaded: true) == .takeItBack)
        #expect(BackgroundExitPolicy.onReturn(shedBrainStillLoaded: false) == .loadAgain)
        let shed = try body(of: "func releaseForBackground()", in: "AppCore.swift")
        let held = try #require(shed.range(of: "shedMLX = currentMLX"))
        let dropped = try #require(shed.range(of: "currentMLX = nil"))
        #expect(held.lowerBound < dropped.lowerBound, "the weak hold is taken before the app lets go")
        let warm = try body(of: "func warmForForeground()", in: "AppCore.swift")
        let asked = try #require(warm.range(of: "BackgroundExitPolicy.onReturn("))
        let warmed = try #require(warm.range(of: "warmSelectedBrain()"))
        #expect(asked.lowerBound < warmed.lowerBound)
        #expect(warm.contains("currentMLX = stillLoaded"))
    }
}
