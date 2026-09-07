//
//  ScreengrabUITests.swift
//  M1K3ScreengrabUITests (macOS)
//
//  One test per App Store plate (marketing/app-store/CAPTURE-PLAN.md §2). Each
//  launches the app under the plate's recipe — M1K3_SCREENGRAB=1 (isolated
//  store root + demo persona) plus `-key value` argument-domain overrides for
//  first-run state and the face — drives to the subject, lets it settle, and
//  captures the WINDOW (never the screen: no desktop, no Dock, no 2FA code).
//
//  Output: an XCTAttachment named after the plate (extracted from the xcresult
//  by tools/screengrab/capture.sh) and, when M1K3_SCREENGRAB_OUT names a
//  directory, the PNG written straight there.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.7 (drives a live
//  app; anchors are the shell's visible labels — verify-by-launch per plate),
//  Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-08 — voice plates wait on the voice surface / the spoken line, not the
//  composer (the beat hides it: 8 plates "composer never appeared"); brain-at-home queries the Settings window only.
//

import M1K3Screengrab
import XCTest

final class ScreengrabUITests: XCTestCase {
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
            waitForText("original roofline", in: app, timeout: 90)
        }
    }

    func testVoiceListening() throws {
        // The open mic feeds the hero question word by word; shoot mid-sentence,
        // before the endpointer could ever consider the partial finished.
        try capture(.voiceListening, settle: 0.5) { app in
            waitForVoiceSurface(app)
            waitForText("call with", in: app, timeout: 30)
        }
    }

    func testVoiceSpeaking() throws {
        // The beat speaks the hero answer ~1.5 s after voice mode; shoot on the
        // karaoke line, mid-sentence.
        try capture(.voiceSpeaking, settle: 1) { app in
            waitForVoiceSurface(app)
            waitForText("roofline", in: app, timeout: 60)
        }
    }

    func testDocuments() throws {
        try capture(.documents, settle: 3) { app in
            // ContentView opens on Documents under this plate; the seed lands async.
            waitForText("Retrofit", in: app, timeout: 90)
        }
    }

    func testMemories() throws {
        try capture(.memories, settle: 3) { app in
            waitForText("memor", in: app, timeout: 90)
        }
    }

    func testBrainAtHome() throws {
        try capture(.brainAtHome, settle: 4, window: settingsWindow) { app in
            // The beat opens Settings (▸ M1K3, whose Brain at Home section runs the ceremony).
            waitForBrain(app)
            let settings = settingsWindow(app)
            XCTAssert(settings.waitForExistence(timeout: 60), "Settings window never appeared")
            // Scoped to the Settings window: a whole-app query over the avatar
            // surface timed out ("Failed to get matching snapshots").
            waitForText("Brain at Home", in: app, scope: settings, timeout: 60)
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
        try capture(.privacyLabel, settle: 3, window: settingsWindow) { app in
            // The beat opens Settings on the Privacy pane.
            waitForBrain(app)
            waitForText("Privacy", in: app, timeout: 60)
        }
    }

    // MARK: - Machinery

    /// The Settings scene's window when it is up, else whatever is frontmost.
    private func settingsWindow(_ app: XCUIApplication) -> XCUIElement {
        let settings = app.windows["M1K3 Settings"]
        return settings.exists ? settings : app.windows.firstMatch
    }

    private func companion(_ plate: ScreengrabPlate) throws {
        // Voice mode is the full-window avatar surface; give the mesh time to load.
        try capture(plate, settle: 8) { app in
            waitForVoiceSurface(app)
        }
    }

    /// Voice mode is up: one of its state captions is on screen. The composer is
    /// hidden the moment the beat enters voice mode, so it is no anchor here.
    private func waitForVoiceSurface(_ app: XCUIApplication, timeout: TimeInterval = 120) {
        let caption = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS[c] 'Listening' OR label CONTAINS[c] 'Tap the face' OR label CONTAINS[c] 'speaking'"
        )).firstMatch
        XCTAssert(caption.waitForExistence(timeout: timeout), "voice surface never appeared")
    }

    /// Launch under the plate's recipe, drive, settle, shoot the window.
    private func capture(
        _ plate: ScreengrabPlate,
        settle: TimeInterval,
        window: ((XCUIApplication) -> XCUIElement)? = nil,
        drive: (XCUIApplication) -> Void
    ) throws {
        let app = XCUIApplication()
        let recipe = plate.launchRecipe
        app.launchEnvironment = recipe.environment
        app.launchArguments = recipe.flatArguments
        addTeardownBlock { app.terminate() } // a failed wait must not leave the app running
        app.launch()
        // A cold launch warms brains + reindexes the seed (~40 s here) and the
        // window may not be key yet: activate, then wait for it to exist.
        app.activate()
        XCTAssert(app.windows.firstMatch.waitForExistence(timeout: 180), "\(plate.rawValue): no window after launch")
        drive(app)
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let target = window?(app) ?? app.windows.firstMatch
        XCTAssert(target.waitForExistence(timeout: 10), "\(plate.rawValue): no window to capture")
        let shot = target.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = plate.rawValue
        attachment.lifetime = .keepAlways
        add(attachment)
        if let out = ProcessInfo.processInfo.environment["M1K3_SCREENGRAB_OUT"], !out.isEmpty {
            let url = URL(fileURLWithPath: out, isDirectory: true).appendingPathComponent("\(plate.rawValue).png")
            try shot.pngRepresentation.write(to: url)
        }
        app.terminate()
    }

    /// The brain-ready signal: the composer's send affordance exists and is enabled.
    private func waitForBrain(_ app: XCUIApplication, timeout: TimeInterval = 90) {
        let ready = NSPredicate(format: "isEnabled == true")
        // The composer is the "Ask M1K3…" field (a vertical-axis TextField).
        let composer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "placeholderValue BEGINSWITH[c] 'Ask M1K3'")).firstMatch
        XCTAssert(composer.waitForExistence(timeout: timeout), "composer never appeared")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: composer)
        // Deliberately non-fatal: a near-miss plate beats no plate. The miss is
        // still on the record so a placeholder-looking capture has a cause.
        if XCTWaiter().wait(for: [expectation], timeout: timeout) != .completed {
            let note = XCTAttachment(string: "composer never became enabled within \(Int(timeout))s — captured anyway")
            note.name = "brain-not-ready"
            note.lifetime = .keepAlways
            add(note)
        }
    }

    private func waitForText(
        _ fragment: String, in app: XCUIApplication, scope: XCUIElement? = nil, timeout: TimeInterval = 30
    ) {
        // Any element type: message text renders through custom views whose
        // accessibility role is not always StaticText.
        let match = (scope ?? app).descendants(matching: .any)
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
