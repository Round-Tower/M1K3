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
//  It also cannot prove WHICH screen it audited. The plate suite found that a
//  text query over the main window aborts XCTest's snapshot, so these tests
//  settle on a timer like the plates do and name no anchor: read a clean
//  report beside the app, never as proof by itself that the screen was up.
//
//  Output: a text attachment per screen named `a11y-<screen>`, and the same
//  report written to `M1K3_A11Y_OUT/<screen>.txt` when that names a directory
//  (`tools/dev/a11y_audit.sh` sets it and prints the combined report).
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.6 (drives a live app
//  through XCTest's snapshot of the whole tree, which the plate suite has seen
//  time out on the main window; verify-by-launch per screen), Prior: Unknown
//  Review: Kev + claude-fable-5.2, 2026-11-14 — findings name their element through
//  `AccessibilityAuditReport.elementName` and say its kind. It also attaches a picture of the window and heads
//  the report with the window's frame, for a11y_contrast.py; the picture is now the answer to "which screen was
//  this".
//

import AppKit
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

        // What was on screen when the audit ran: the Mac suite names no anchor, so this picture
        // is the proof of which screen the report is about, and what a contrast finding is measured on.
        // The runner has no window-server connection until AppKit makes one; without it the
        // screenshot aborts the whole run (`CGS_REQUIRE_INIT`, 2026-11-14).
        _ = NSApplication.shared
        let shot = app.windows.firstMatch.screenshot()
        let picture = XCTAttachment(screenshot: shot)
        picture.name = "a11y-shot-\(plate.rawValue)"
        picture.lifetime = .keepAlways
        add(picture)

        let collected = Collected()
        var incomplete = ""
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                collected.findings.append(AccessibilityAuditFinding(
                    screen: plate.rawValue,
                    kind: Self.name(of: issue.auditType),
                    element: Self.name(of: issue.element),
                    detail: Self.detail(of: issue),
                    place: Self.place(of: issue.element)
                ))
                return true // handled: keep going, the report carries it
            }
        } catch {
            // The audit itself could not run (a tree snapshot timed out): say so
            // rather than report a clean screen.
            XCTFail("\(plate.rawValue): the audit did not complete: \(error.localizedDescription)")
            incomplete = "AUDIT DID NOT COMPLETE: \(error.localizedDescription) — the list below is partial, not a clean screen.\n"
        }

        // The window's frame, so `a11y_contrast.py` can place each finding on the screenshot.
        let window = "WINDOW \(app.windows.firstMatch.frame)\n"
        let report = window + incomplete + AccessibilityAuditReport.render(collected.findings)
        let attachment = XCTAttachment(string: report)
        attachment.name = "a11y-\(plate.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let out = ProcessInfo.processInfo.environment["M1K3_A11Y_OUT"], !out.isEmpty {
            let url = URL(fileURLWithPath: out, isDirectory: true).appendingPathComponent("\(plate.rawValue).txt")
            // Best-effort: the attachment above is the record if the runner cannot write here.
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
        let found = AccessibilityAuditReport.unique(collected.findings)
        XCTAssert(found.isEmpty, "\(plate.rawValue): \(AccessibilityAuditReport.summary(found))")
        app.terminate()
    }

    /// Xcode's wording plus what kind of element it is: a named element ("bolt.fill") is
    /// otherwise impossible to place.
    private static func detail(of issue: XCUIAccessibilityAuditIssue) -> String {
        guard let element = issue.element, element.exists else { return issue.compactDescription }
        return "\(issue.compactDescription) (\(name(of: element.elementType)))"
    }

    private static func name(of element: XCUIElement?) -> String {
        guard let element, element.exists else { return "" }
        return AccessibilityAuditReport.elementName(
            label: element.label,
            identifier: element.identifier,
            title: element.title,
            value: (element.value as? String) ?? "",
            type: Self.name(of: element.elementType),
            frame: "\(element.frame)"
        )
    }

    private static func name(of type: XCUIElement.ElementType) -> String {
        let known: [XCUIElement.ElementType: String] = [
            .button: "button", .staticText: "static text", .image: "image", .group: "group",
            .other: "element", .textField: "text field", .textView: "text view", .cell: "cell",
            .scrollView: "scroll view", .table: "table", .outline: "outline", .outlineRow: "outline row",
            .tableRow: "row", .toolbar: "toolbar", .toolbarButton: "toolbar button", .window: "window",
            .splitGroup: "split group", .splitter: "splitter", .checkBox: "checkbox", .toggle: "toggle",
            .switch: "switch", .popUpButton: "pop-up button", .menuButton: "menu button", .link: "link",
            .disclosureTriangle: "disclosure triangle", .scrollBar: "scroll bar", .slider: "slider",
            .progressIndicator: "progress indicator", .segmentedControl: "segmented control",
            .radioButton: "radio button", .tabGroup: "tab group", .navigationBar: "navigation bar",
            .collectionView: "collection view", .secureTextField: "secure text field",
        ]
        return known[type] ?? "element type \(type.rawValue)"
    }

    private static func place(of element: XCUIElement?) -> String {
        guard let element, element.exists else { return "" }
        return "\(element.frame)"
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
