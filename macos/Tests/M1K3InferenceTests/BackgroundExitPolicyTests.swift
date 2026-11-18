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

    @Test("the inactive stop follows the background rule exactly, so nothing off-GPU is stopped early")
    func inactiveStopMatchesTheExitRule() {
        for turn in [true, false] {
            for gpu in [true, false] {
                #expect(
                    BackgroundExitPolicy.stopsTurnAtInactive(turnInFlight: turn, brainRunsOnThisDevicesGPU: gpu)
                        == BackgroundExitPolicy.stopsTurn(turnInFlight: turn, brainRunsOnThisDevicesGPU: gpu)
                )
            }
        }
    }

    @Test("the shed waits for a running turn, and only for the bound")
    func shedWaitsBounded() {
        #expect(BackgroundExitPolicy.shedPlan(chatResponding: true, mlxEvaluating: false, waited: .zero) == .waitForTurn)
        #expect(
            BackgroundExitPolicy.shedPlan(chatResponding: true, mlxEvaluating: true, waited: .milliseconds(900))
                == .waitForTurn
        )
        #expect(BackgroundExitPolicy.shedPlan(chatResponding: true, mlxEvaluating: true, waited: .seconds(1)) == .shedNow)
        #expect(BackgroundExitPolicy.shedPlan(chatResponding: false, mlxEvaluating: false, waited: .zero) == .shedNow)
        #expect(BackgroundExitPolicy.shedWaitLimit <= .seconds(1))
    }

    @Test("a side generation with no chat turn (a title, a distillation) makes the shed wait too (#862)")
    func shedWaitsForASideGeneration() {
        #expect(BackgroundExitPolicy.shedPlan(chatResponding: false, mlxEvaluating: true, waited: .zero) == .waitForTurn)
        #expect(BackgroundExitPolicy.shedPlan(chatResponding: false, mlxEvaluating: true, waited: .seconds(1)) == .shedNow)
    }

    @Test("the phone stops an on-device turn at .inactive, without touching speech or voice")
    func theShellStopsAtInactive() throws {
        let app = try String(contentsOf: Self.shell.appendingPathComponent("M1K3iOSHarnessApp.swift"), encoding: .utf8)
        #expect(app.components(separatedBy: "case .inactive:").count == 2)
        let inactive = try #require(app.range(of: "case .inactive:"))
        let background = try #require(app.range(of: "case .background:"))
        let arm = app[inactive.upperBound ..< background.lowerBound]
        #expect(arm.contains("core?.stopTurnForInactive()"))
        #expect(!arm.contains("exitVoiceMode") && !arm.contains("releaseForBackground"))
        let body = try body(of: "func stopTurnForInactive()", in: "AppCore.swift")
        #expect(body.contains("BackgroundExitPolicy.stopsTurnAtInactive("))
        #expect(body.contains("chat.stopResponding()"))
        #expect(!body.contains("stopSpeakingAnswer"))
    }

    @Test("the shed asks the policy and waits for the turn before it lets go of anything")
    func theShedWaitsForTheTurn() throws {
        let shed = try body(of: "func releaseForBackground()", in: "AppCore.swift")
        #expect(shed.contains("BackgroundExitPolicy.shedPlan("))
        #expect(shed.contains("chat.isResponding"))
        #expect(shed.contains("MLXBrainProvider.evaluating"), "a title or a distillation in flight counts too (#862)")
        #expect(!shed.contains("releaseMemory()"), "the release itself lives in shedBrain, behind the wait")
        let release = try body(of: "func shedBrain()", in: "AppCore.swift")
        #expect(release.contains("releaseMemory()"))
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

    @Test("a Private Cloud turn runs on Apple's servers even with Lil loaded here: it is not this device's GPU")
    func privateCloudTurnIsNotThisGPU() {
        #expect(BackgroundExitPolicy.turnUsesThisDevicesGPU(localBrainLoaded: true, privateCloudTurn: false))
        #expect(!BackgroundExitPolicy.turnUsesThisDevicesGPU(localBrainLoaded: true, privateCloudTurn: true))
        #expect(!BackgroundExitPolicy.turnUsesThisDevicesGPU(localBrainLoaded: false, privateCloudTurn: false))
        #expect(!BackgroundExitPolicy.turnUsesThisDevicesGPU(localBrainLoaded: false, privateCloudTurn: true))
    }

    @Test("every stop and the Live Activity read the turn's route, never the loaded brain alone")
    func theShellReadsTheRoute() throws {
        let source = try String(contentsOf: Self.shell.appendingPathComponent("AppCore.swift"), encoding: .utf8)
        #expect(!source.contains("brainRunsOnThisDevicesGPU: currentMLX != nil"), "a Private Cloud turn with Lil loaded")
        for function in ["func stopForBackground()", "func stopTurnForInactive()"] {
            let body = try body(of: function, in: "AppCore.swift")
            #expect(body.contains("brainRunsOnThisDevicesGPU: turnUsesThisDevicesGPU"), "\(function)")
        }
        // The route comes from the session (the streaming answer's origin), never a flag around the send: a failed
        // Private Cloud turn falls back to Lil inside the same call (review, 2026-11-17).
        let route = try body(of: "var turnUsesThisDevicesGPU", in: "AppCore.swift")
        #expect(route.contains("chat.answeringOnPrivateCloud"))
        #expect(!source.contains("privateCloudTurnInFlight"))
    }

    @Test("a brain still in memory on the return is taken back, never loaded a second time")
    func theReturnNeverLoadsBesideALiveBrain() throws {
        #expect(BackgroundExitPolicy.onReturn(shedBrainStillLoaded: true) == .takeItBack)
        #expect(BackgroundExitPolicy.onReturn(shedBrainStillLoaded: false) == .loadAgain)
        let shed = try body(of: "func shedBrain()", in: "AppCore.swift")
        let held = try #require(shed.range(of: "shedMLX = currentMLX"))
        let dropped = try #require(shed.range(of: "currentMLX = nil"))
        #expect(held.lowerBound < dropped.lowerBound, "the weak hold is taken before the app lets go")
        let warm = try body(of: "func warmForForeground()", in: "AppCore.swift")
        let asked = try #require(warm.range(of: "BackgroundExitPolicy.onReturn("))
        let warmed = try #require(warm.range(of: "warmSelectedBrain()"))
        #expect(asked.lowerBound < warmed.lowerBound)
        #expect(warm.contains("currentMLX = stillLoaded"))
    }

    /// #864 review: a Private Cloud turn left running in the background can still fail there, and its local
    /// fallback would then start Lil on a GPU iOS refuses in the background.
    @Test("a Private Cloud turn's local fallback runs in front, or anywhere when the local brain is not on this GPU")
    func localFallbackOnlyWhereTheGPUServes() {
        #expect(BackgroundExitPolicy.mayRunLocalFallback(appActive: true, localBrainLoaded: true))
        #expect(BackgroundExitPolicy.mayRunLocalFallback(appActive: false, localBrainLoaded: false), "Mini or Home")
        #expect(!BackgroundExitPolicy.mayRunLocalFallback(appActive: false, localBrainLoaded: true))
    }
}
