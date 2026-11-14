//
//  AccessibilityAuditiOSUITests.swift
//  M1K3iOSScreengrabUITests
//
//  Xcode's accessibility audit on the iPhone / iPad screens, the twin of the Mac
//  suite: launch under a plate's recipe (isolated store + demo persona), wait
//  for the screen's own words, and run `performAccessibilityAudit`. Every issue
//  is collected, so one run gives the whole list for a screen.
//
//  The phone audit adds what the Mac one cannot do: text that does not scale
//  with Dynamic Type, clipped text and wrong traits, next to contrast, missing
//  descriptions and small hit regions. Run it a second time at the largest text
//  size (`tools/dev/a11y_audit.sh ios <udid> --largest-text`, Simulator only) for
//  the Larger Text label. It cannot check whether VoiceOver or Voice Control
//  lets someone finish a task: that stays a hand run.
//
//  A screen whose anchor never appears is audited anyway and the miss is failed
//  by name, so a screen behind a brain the Simulator cannot run reads as
//  "not reached", never as clean.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.6 (drives a live
//  app; the anchors are the plate suite's; verify-by-launch per screen), Prior: Unknown
//

import M1K3Screengrab
import XCTest

// Main-actor: `performAccessibilityAudit` is, and its callback collects into this test's own state.
@MainActor
final class AccessibilityAuditiOSUITests: XCTestCase {
    func testOnboarding() throws {
        try audit(.onboarding, anchor: "Pick a brain", timeout: 30)
    }

    func testChat() throws {
        try audit(.chat, anchor: "Nobody else is listening", timeout: 120)
    }

    func testDocuments() throws {
        try audit(.documents, anchor: "Lair", timeout: 180)
    }

    func testMemories() throws {
        try audit(.memories, anchor: "roofline", timeout: 180)
    }

    func testSettingsBrainAtHome() throws {
        try audit(.brainAtHome, anchor: "Codes expire", timeout: 180)
    }

    func testSettingsPrivacy() throws {
        try audit(.privacyLabel, anchor: "sends your conversation", timeout: 180)
    }

    func testVoice() throws {
        try audit(.voiceListening, anchor: "Listening", timeout: 120)
    }

    // MARK: - Machinery

    /// Collects across the audit's callback, which XCTest calls once per issue.
    private final class Collected {
        var findings: [AccessibilityAuditFinding] = []
    }

    private func audit(_ plate: ScreengrabPlate, anchor: String, timeout: TimeInterval) throws {
        // One screen's issues must not stop the report for it being written.
        continueAfterFailure = true
        let app = XCUIApplication()
        let recipe = plate.launchRecipe
        app.launchEnvironment = recipe.environment
        app.launchArguments = recipe.flatArguments
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssert(app.wait(for: .runningForeground, timeout: 60), "\(plate.rawValue): app never came foreground")
        let reached = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", anchor, anchor)).firstMatch
            .waitForExistence(timeout: timeout)
        XCTAssert(reached, "\(plate.rawValue): '\(anchor)' never appeared — the audit below is of the wrong screen")
        RunLoop.current.run(until: Date().addingTimeInterval(3))

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
            XCTFail("\(plate.rawValue): the audit did not complete: \(error.localizedDescription)")
            incomplete = "AUDIT DID NOT COMPLETE: \(error.localizedDescription) — the list below is partial, not a clean screen.\n"
        }

        let heading = reached ? "" : "NOT REACHED: '\(anchor)' never appeared, so this is another screen's audit.\n"
        let report = heading + incomplete + AccessibilityAuditReport.render(collected.findings)
        let attachment = XCTAttachment(string: report)
        attachment.name = "a11y-\(plate.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
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
            (.dynamicType, "text does not scale"),
            (.textClipped, "text clipped"),
            (.trait, "trait"),
            (.elementDetection, "element detection"),
            (.hitRegion, "hit region"),
            (.sufficientElementDescription, "description"),
        ]
        return known.first { type.contains($0.0) }?.1 ?? "other (\(type.rawValue))"
    }
}
