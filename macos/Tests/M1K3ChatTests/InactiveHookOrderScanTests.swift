import Foundation
import Testing

/// The phone's `.inactive` handler does three things in ONE order: the Live Activity card starts (still
/// foreground), then the on-device stop runs (#858), and inside the stop the card is told "Paused" before
/// the turn is cut. Two `case .inactive:` arms (the shape a merge produces) would silently drop one of them,
/// since Swift matches the first. A source scan pins both, because the shell cannot run under `swift test`.
struct InactiveHookOrderScanTests {
    private func source(_ relative: String) throws -> String {
        let macos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: macos.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("the harness has one .inactive arm: card first, only from .active, then the on-device stop")
    func harnessInactiveOrder() throws {
        let text = try source("M1K3iOSApp/M1K3iOSHarnessApp.swift")
        #expect(text.components(separatedBy: "case .inactive:").count == 2, "exactly one .inactive arm")
        let card = try #require(text.range(of: "core?.turnActivityGoingInactive()"))
        let stop = try #require(text.range(of: "core?.stopTurnForInactive()"))
        #expect(card.lowerBound < stop.lowerBound)
        #expect(text.contains("if previous == .active { core?.turnActivityGoingInactive() }"))
    }

    @Test("stopTurnForInactive tells the Live Activity before it stops the turn")
    func pausedBeforeTheStop() throws {
        let text = try source("M1K3iOSApp/AppCore.swift")
        let body = try #require(text.range(of: "func stopTurnForInactive()"))
        let rest = String(text[body.upperBound...])
        let paused = try #require(rest.range(of: "turnActivity.stoppingAtInactive("))
        let stop = try #require(rest.range(of: "chat.stopResponding()"))
        #expect(paused.lowerBound < stop.lowerBound)
    }
}
