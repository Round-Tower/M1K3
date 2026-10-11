//
//  OnboardingDeckScanTests.swift
//  M1K3AvatarTests
//
//  Source-scan pins on the onboarding fix (Kev, TestFlight 2026-10-11: "Re-run onboarding… was
//  slow, and I only saw the name / experience page"; #540 defect 1). HelloView is a SwiftUI body
//  with no pure seam (the pure rule is WakeSetupFlow, pinned in M1K3InferenceTests), so these
//  read the shell files from disk (the SettingsPaneLayoutTests idiom) and match on strings:
//    · finishHello never completes straight after the doors on a re-run or a ready first run;
//    · the carousel is mounted by a phase outside the two waits;
//    · the first frame carries no synchronous AFM probe, and the backdrop mounts after the card;
//    · the Re-run button starts the stopwatch.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.6 (coarse tripwires over text; the
//  sheet's speed and look are verify-by-launch on TestFlight). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — pins the folds: no synchronous
//  AFM probe anywhere in the sheet, re-run doors never wait on AFM, a 3 s timeout, placeholder copy
//  until AFM lands, and the already-loaded fallback edge shows the deck. Confidence 0.65.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — the polish pass (TestFlight 499): centring anchor, shared glass
//  card with the progress footer kept outside it, pixel titles, glass buttons, earcon wiring order. Confidence 0.6
//  (text tripwires; how it looks and sounds is verify-by-launch).
//

import Foundation
import Testing

struct OnboardingDeckScanTests {
    private static func code(_ relative: String) throws -> String {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(!src.isEmpty, "scan read an empty file — \(relative) moved")
        return src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The text from `start` up to (not including) the next `end`, or a failed expectation.
    private static func slice(_ code: String, from start: String, to end: String) -> String {
        guard let lower = code.range(of: start),
              let upper = code.range(of: end, range: lower.upperBound ..< code.endIndex)
        else {
            Issue.record("scan could not find \(start) … \(end)")
            return ""
        }
        return String(code[lower.lowerBound ..< upper.lowerBound])
    }

    @Test("finishHello's re-run branch no longer completes straight after the doors")
    func rerunBranchDoesNotComplete() throws {
        let code = try Self.code("M1K3App/HelloView.swift")
        let branch = Self.slice(code, from: "env.avatar.setEmotion(.excited)", to: "switch FirstRunBrainPolicy")
        #expect(!branch.isEmpty)
        #expect(!branch.contains("onComplete()"), "the re-run branch skips the deck again")
        #expect(branch.contains("showSetupDeck()"))
    }

    @Test("a first run on a ready brain (keepCurrent / useMini) shows the deck, not onComplete")
    func readyFirstRunShowsDeck() throws {
        let code = try Self.code("M1K3App/HelloView.swift")
        let ready = Self.slice(code, from: "case let .keepCurrent(tier):\n            env.selectBrain", to: "case .waitForMini:")
        #expect(!ready.contains("onComplete()"), "a ready first run skips the deck again")
        #expect(ready.components(separatedBy: "showSetupDeck()").count - 1 == 2)
        let helper = Self.slice(code, from: "private func showSetupDeck()", to: "private func startFallbackDownload")
        #expect(helper.contains("phase = .setup"))
        #expect(helper.contains("WakeSetupFlow(brainAlreadyReady: true)"))
    }

    @Test("HelloView mounts the carousel for a setup phase outside the two waits")
    func carouselMountedOutsideWaits() throws {
        let code = try Self.code("M1K3App/HelloView.swift")
        #expect(code.contains("case setup"))
        #expect(code.contains("case .setup: setupCard"))
        let card = Self.slice(code, from: "private var setupCard", to: "private var waitingCard")
        #expect(card.contains("WakeSetupCarousel("))
        #expect(card.contains("fraction: nil"))
        #expect(code.contains("WakeSetupFlow(brainAlreadyReady: true)"))
    }

    @Test("the first frame carries no synchronous AFM probe and the backdrop mounts after the card")
    func firstFrameIsLight() throws {
        let code = try Self.code("M1K3App/HelloView.swift")
        let onAppear = Self.slice(code, from: ".onAppear {", to: ".onDisappear {")
        #expect(!onAppear.contains("env.afmAvailability"), "the AFM probe is back on the first frame")
        // No synchronous probe anywhere in the sheet: the first read and the Mini-wait poll both
        // go through the detached reader.
        #expect(!code.contains("env.afmAvailability"), "a synchronous AFM probe is back in HelloView")
        #expect(code.contains("afm = await Self.readAFM()"), "AFM availability should be read in a .task")
        #expect(code.contains("backdropReady"), "the backdrop should mount after the card is visible")
    }

    @Test("the doors wait on AFM only on a first run, never past a 3 s timeout, with no copy flip")
    func doorsNeverDeadOnRerun() throws {
        let code = try Self.code("M1K3App/HelloView.swift")
        #expect(code.contains("!afmKnown && !isRerun"), "a re-run's doors wait on a value it never reads")
        #expect(code.components(separatedBy: ".disabled(settling || doorsWaitingOnAFM)").count - 1 == 2)
        #expect(code.contains("hello afm read timed out"), "a hung probe would leave the doors dead")
        #expect(code.contains(".redacted(reason: doorsWaitingOnAFM ? .placeholder : [])"))
    }

    @Test("an already-loaded fallback brain is a no-wait path too: the deck, not onComplete")
    func alreadyLoadedFallbackShowsDeck() throws {
        let code = try Self.code("M1K3App/HelloView.swift")
        let fallback = Self.slice(code, from: "private func startFallbackDownload", to: "private func settleFullPermissions")
        #expect(fallback.contains("showSetupDeck()"))
        #expect(!fallback.contains("onComplete()"), "the already-loaded edge skips the deck again")
    }

    // MARK: - The polish pass (Kev, TestFlight 499: centred, liquid glass, pixel title, sounds)

    @Test("HelloView centres every phase and carries no dead spacers")
    func helloViewCentresEveryPhase() throws {
        let code = try Self.code("M1K3App/HelloView.swift")
        #expect(code.contains(".defaultScrollAnchor(.center, for: .alignment)"))
        let phases = Self.slice(code, from: "private var setupCard", to: "private var downloadFraction")
        #expect(!phases.contains("Spacer(minLength: 20)"), "the spacers the anchor replaced are back")
    }

    @Test("the hello card and the deck wear the shared Liquid Glass card, not a material")
    func glassCards() throws {
        let hello = try Self.code("M1K3App/HelloView.swift")
        let card = Self.slice(hello, from: "private var helloCard", to: "private var needsFallbackDownload")
        #expect(card.contains(".onboardingCard()"))
        #expect(!card.contains(".regularMaterial"))

        let glass = try Self.code("M1K3App/OnboardingGlass.swift")
        #expect(glass.contains(".glassEffect("))
        #expect(glass.contains("cornerRadius: 26"))
        #expect(glass.contains("maxWidth: 560"))

        let deck = try Self.code("M1K3App/WakeSetupCarousel.swift")
        #expect(deck.contains(".onboardingCard()"))
        // The progress footer re-renders on every download tick: it must stay OUTSIDE the glass
        // (the NSGenericException layout crash, ContentView.swift's banner comment).
        let body = Self.slice(deck, from: "var body: some View", to: "@ViewBuilder private var card")
        let glassAt = try #require(body.range(of: ".onboardingCard()"))
        let footerAt = try #require(body.range(of: "progressFooter"))
        #expect(glassAt.lowerBound < footerAt.lowerBound, "the footer moved inside the glass card")
        let footer = Self.slice(deck, from: "@ViewBuilder private var progressFooter", to: "private func nudgeAlertness")
        #expect(!footer.contains(".onboardingCard()") && !footer.contains(".glassEffect("))
    }

    @Test("the deck title and card titles wear the pixel face")
    func pixelTitles() throws {
        let deck = try Self.code("M1K3App/WakeSetupCarousel.swift")
        let title = Self.slice(deck, from: "Text(flow.userDrivenCompletion", to: "card\n")
        #expect(title.contains(".font(.pixel(28))"))
        #expect(!title.contains(".foregroundStyle(.secondary)"), "the title is full opacity")
        let cardTitle = Self.slice(deck, from: "private func cardTitle", to: "private func cardCaption")
        #expect(cardTitle.contains(".font(.pixelTitle)"))
    }

    @Test("the chevrons are round glass in a container; Done is a content-sized prominent capsule")
    func glassButtons() throws {
        let deck = try Self.code("M1K3App/WakeSetupCarousel.swift")
        let nav = Self.slice(deck, from: "private var navigation", to: "@ViewBuilder private var progressFooter")
        #expect(nav.contains("GlassEffectContainer(spacing: 16)"))
        #expect(nav.components(separatedBy: ".buttonBorderShape(.circle)").count - 1 == 2)
        #expect(nav.components(separatedBy: ".controlSize(.large)").count - 1 == 2)
        let footer = Self.slice(deck, from: "@ViewBuilder private var progressFooter", to: "private func nudgeAlertness")
        let buttons = Self.slice(footer, from: "case .invite where", to: "case .autoComplete")
        #expect(!buttons.contains(".frame(maxWidth: .infinity)"), "the Done label is full-width again")
        #expect(!buttons.contains(".frame(maxWidth: 360)"))
        #expect(buttons.components(separatedBy: ".buttonStyle(.glassProminent)").count - 1 == 2)
        #expect(buttons.components(separatedBy: ".controlSize(.large)").count - 1 == 2)
    }

    @Test("the earcons are wired where Kev asked: door, turn, selection, wake, done")
    func earconsAreWired() throws {
        let hello = try Self.code("M1K3App/HelloView.swift")
        let sayHello = Self.slice(hello, from: "private func sayHello", to: "private func finishHello")
        let pick = try #require(sayHello.range(of: "soundEffects.play(.doorPick)"))
        let ceremony = try #require(sayHello.range(of: "settling = true"))
        #expect(pick.lowerBound < ceremony.lowerBound, "the door sound must precede the permission ceremony")

        let deck = try Self.code("M1K3App/WakeSetupCarousel.swift")
        #expect(deck.contains("soundEffects.play(.cardTurn)"))
        #expect(deck.components(separatedBy: "soundEffects.play(.selectionTick)").count - 1 >= 3)
        #expect(deck.contains("soundEffects.play(.doneChord)"))
        let greet = Self.slice(deck, from: "private func greetOnce", to: "private func sayHi")
        let chime = try #require(greet.range(of: "soundEffects.play(.wakeChime)"))
        let speak = try #require(greet.range(of: "env.speak("))
        #expect(chime.lowerBound < speak.lowerBound, "the chime must start before M1K3 speaks (earcons mute then)")
        #expect(deck.contains("OnboardingVoiceLine.line(isRerun:"))
    }

    @Test("the Re-run button starts the onboarding stopwatch")
    func rerunButtonStartsTrace() throws {
        let code = try Self.code("M1K3App/Settings/GeneralSettingsPane.swift")
        #expect(code.contains("OnboardingTrace.shared.begin()"))
    }
}
