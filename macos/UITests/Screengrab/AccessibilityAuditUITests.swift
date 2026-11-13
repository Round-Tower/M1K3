//
//  AccessibilityAuditUITests.swift
//  M1K3ScreengrabUITests (macOS)
//
//  Xcode's accessibility audit, run on the screens the App Store plates already
//  know how to reach. Each test launches the app under a plate's recipe (the
//  isolated store + demo persona, never the owner's data), lets the screen
//  settle, and runs `performAccessibilityAudit`. Every issue is collected, not
//  thrown on the first, so one run gives the whole list for a screen.
//
//  What it checks on the Mac: contrast, elements with no description, hit
//  regions, elements the tree hides, parent/child structure and actions.
//  What it cannot check: whether VoiceOver or Voice Control lets someone finish
//  a task. That stays a hand run before any store accessibility label is claimed.
//
//  Output: a text attachment per screen named `a11y-<screen>`, and the same
//  report written to `M1K3_A11Y_OUT/<screen>.txt` when that names a directory
//  (`tools/dev/a11y_audit.sh` sets it and prints the combined report).
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.6 (drives a live app
//  through XCTest's snapshot of the whole tree, which the plate suite has seen
//  time out on the main window; verify-by-launch per screen), Prior: Unknown
//

import M1K3Screengrab
import XCTest

// Main-actor: `performAccessibilityAudit` is, and its callback collects into this test's own state.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
    func testOnboarding() throws {
        try audit(.onboarding, settle: 3)
    }

    func testChat() throws {
        try audit(.chat, settle: 12)
    }

    func testDocuments() throws {
        try audit(.documents, settle: 12)
    }

    func testMemories() throws {
        try audit(.memories, settle: 12)
    }

    func testSettingsBrainAtHome() throws {
        try audit(.brainAtHome, settle: 8)
    }

    func testSettingsPrivacy() throws {
        try audit(.privacyLabel, settle: 8)
    }

    func testVoice() throws {
        // The open mic is dictating by now, so this is the voice surface mid-listen.
        try audit(.voiceListening, settle: 18)
    }

    // MARK: - Machinery

    /// Collects across the audit's callback, which XCTest calls once per issue.
    private final class Collected {
        var findings: [AccessibilityAuditFinding] = []
    }

    private func audit(_ plate: ScreengrabPlate, settle: TimeInterval) throws {
        // One screen's issues must not stop the report for it being written.
        continueAfterFailure = true
        let app = XCUIApplication()
        let recipe = plate.launchRecipe
        app.launchEnvironment = recipe.environment
        if let run = ProcessInfo.processInfo.environment[ScreengrabHarness.runKey], !run.isEmpty {
            app.launchEnvironment[ScreengrabHarness.runKey] = run
        }
        app.launchArguments = recipe.flatArguments
        addTeardownBlock { app.terminate() }
        app.launch()
        app.activate()
        XCTAssert(app.windows.firstMatch.waitForExistence(timeout: 180), "\(plate.rawValue): no window after launch")
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        app.activate()

        let collected = Collected()
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                collected.findings.append(AccessibilityAuditFinding(
                    screen: plate.rawValue,
                    kind: Self.name(of: issue.auditType),
                    element: Self.name(of: issue.element),
                    detail: issue.compactDescription
                ))
                return true // handled: keep going, the report carries it
            }
        } catch {
            // The audit itself could not run (a tree snapshot timed out): say so
            // rather than report a clean screen.
            XCTFail("\(plate.rawValue): the audit did not complete: \(error.localizedDescription)")
        }

        let report = AccessibilityAuditReport.render(collected.findings)
        let attachment = XCTAttachment(string: report)
        attachment.name = "a11y-\(plate.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let out = ProcessInfo.processInfo.environment["M1K3_A11Y_OUT"], !out.isEmpty {
            let url = URL(fileURLWithPath: out, isDirectory: true).appendingPathComponent("\(plate.rawValue).txt")
            try report.write(to: url, atomically: true, encoding: .utf8)
        }
        let found = AccessibilityAuditReport.unique(collected.findings)
        XCTAssert(found.isEmpty, "\(plate.rawValue): \(AccessibilityAuditReport.summary(found))")
        app.terminate()
    }

    private static func name(of element: XCUIElement?) -> String {
        guard let element, element.exists else { return "" }
        let label = element.label
        return label.isEmpty ? element.identifier : label
    }

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        let known: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"),
            (.elementDetection, "element detection"),
            (.hitRegion, "hit region"),
            (.sufficientElementDescription, "description"),
            (.parentChild, "parent/child"),
            (.action, "action"),
        ]
        return known.first { type.contains($0.0) }?.1 ?? "other (\(type.rawValue))"
    }
}
