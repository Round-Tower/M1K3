//
//  ScreengrabiOSUITests.swift
//  M1K3iOSScreengrabUITests
//
//  One test per App Store plate (marketing/app-store/CAPTURE-PLAN.md §1), the
//  iPhone/iPad twin of the Mac suite: launch under the plate's recipe
//  (M1K3_SCREENGRAB=1 → isolated store root + demo persona, `-key value`
//  argument-domain overrides for first-run state and the face), drive to the
//  subject, settle, capture the screen. Run on a PHYSICAL device — the MLX
//  brains need the real GPU; the Simulator can't show the app doing its job.
//
//  Output: an XCTAttachment named after the plate; tools/screengrab/capture.sh
//  extracts them from the xcresult into marketing/app-store/plates/<target>/.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.65 (drives a live
//  device; anchors are the shell's labels — verify-by-launch per plate),
//  Prior: Unknown
//

import M1K3Screengrab
import XCTest

final class ScreengrabiOSUITests: XCTestCase {
    override func setUp() {
        // A missed anchor is reported, but the plate is STILL captured — a
        // near-miss plate beats no plate, and the attachment shows what was up.
        continueAfterFailure = true
    }

    // MARK: - Plates

    func testOnboarding() throws {
        try capture(.onboarding, settle: 3) { app in
            waitForText("brain", in: app)
        }
    }

    func testChat() throws {
        try capture(.chat, settle: 3) { app in
            waitForText("original roofline", in: app, timeout: 120)
        }
    }

    func testVoiceListening() throws {
        try capture(.voiceListening, settle: 6) { app in waitForBrain(app) }
    }

    func testVoiceSpeaking() throws {
        try capture(.voiceSpeaking, settle: 4) { app in waitForBrain(app) }
    }

    func testDocuments() throws {
        try capture(.documents, settle: 3) { app in
            waitForBrain(app)
            openSettings(app)
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Documents'")).firstMatch.tap()
            waitForText("Retrofit", in: app, timeout: 60)
        }
    }

    func testMemories() throws {
        try capture(.memories, settle: 3) { app in
            waitForBrain(app)
            openSettings(app)
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Memories'")).firstMatch.tap()
            let search = app.searchFields.firstMatch
            XCTAssert(search.waitForExistence(timeout: 30), "Memories search field")
            search.tap()
            search.typeText("architect\n")
            waitForText("Niamh", in: app, timeout: 60)
        }
    }

    func testBrainAtHome() throws {
        try capture(.brainAtHome, settle: 4) { app in
            waitForBrain(app)
            openSettings(app)
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Home'")).firstMatch.tap()
            waitForText("Mac", in: app, timeout: 30)
        }
    }

    func testCompanionFox() throws {
        try companion(.companionFox)
    }

    func testCompanionGecko() throws {
        try companion(.companionGecko)
    }

    func testCompanionInkfish() throws {
        try companion(.companionInkfish)
    }

    func testCompanionColobus() throws {
        try companion(.companionColobus)
    }

    func testPrivacyLabel() throws {
        // Stand-in until the live listing's privacy card exists (plan §1 #12):
        // Settings' Grounding footer — the promise in the app's own words.
        try capture(.privacyLabel, settle: 3) { app in
            waitForBrain(app)
            openSettings(app)
            let footer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'internet'")).firstMatch
            if footer.waitForExistence(timeout: 20) { app.swipeUp(); app.swipeUp() }
        }
    }

    // MARK: - Machinery

    private func companion(_ plate: ScreengrabPlate) throws {
        try capture(plate, settle: 8) { app in waitForBrain(app) }
    }

    private func capture(
        _ plate: ScreengrabPlate,
        settle: TimeInterval,
        drive: (XCUIApplication) -> Void
    ) throws {
        let app = XCUIApplication()
        let recipe = plate.launchRecipe
        app.launchEnvironment = recipe.environment
        app.launchArguments = recipe.flatArguments
        addTeardownBlock { app.terminate() } // a failed wait must not leave the app running
        app.launch()
        XCTAssert(app.wait(for: .runningForeground, timeout: 60), "\(plate.rawValue): app never came foreground")
        drive(app)
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = plate.rawValue
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    private func openSettings(_ app: XCUIApplication) {
        let gear = app.buttons["Settings"].firstMatch
        XCTAssert(gear.waitForExistence(timeout: 30), "Settings toolbar button")
        gear.tap()
    }

    /// Brain-ready: the composer exists and accepts input.
    private func waitForBrain(_ app: XCUIApplication, timeout: TimeInterval = 180) {
        let composer = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssert(composer.waitForExistence(timeout: timeout), "composer never appeared")
        let ready = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: composer)
        XCTWaiter().wait(for: [expectation], timeout: timeout)
    }

    private func waitForText(_ fragment: String, in app: XCUIApplication, timeout: TimeInterval = 30) {
        // Any element type: message text renders through custom views whose
        // accessibility role is not always StaticText.
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", fragment, fragment)).firstMatch
        guard !match.waitForExistence(timeout: timeout) else { return }
        XCTFail("'\(fragment)' never appeared")
        // The element tree (text only — never a screen capture) for the post-mortem.
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "tree-\(fragment)"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
