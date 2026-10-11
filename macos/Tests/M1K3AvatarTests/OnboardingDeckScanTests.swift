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
//  Review: Kev + claude-opus-5.5, 2026-10-11 (PR 2b) — the kit card: no ProgressView inside the glass, a fixed
//  live-bar slot beneath it, one download verb, Done never waits; the semantic-memory offer's wiring. Confidence 0.6.
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

    @Test("the hello card and the deck wear the shared Liquid Glass card (material only beside live progress)")
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
        // Glass, except beside a live download bar: material there (the banner crash's own fix).
        #expect(deck.contains(".onboardingCard(nearLiveProgress: fraction != nil)"))
        #expect(glass.contains("if nearLiveProgress"), "the material fallback beside live progress is gone")
        #expect(glass.contains(".regularMaterial"))
        // The progress footer re-renders on every download tick: it must stay OUTSIDE the glass
        // (the NSGenericException layout crash, ContentView.swift's banner comment), and its height
        // is reserved so a wrapping progress line can't reflow the centred stack mid-download.
        let body = Self.slice(deck, from: "var body: some View", to: "@ViewBuilder private var card")
        #expect(!body.contains("minHeight: 64"), "the blanket footer reserve is back (it padded the Done button)")
        #expect(body.contains("minHeight: Self.cardSlotHeight"), "the card slot lost its fixed height: the chevrons jump")
        let glassAt = try #require(body.range(of: ".onboardingCard(nearLiveProgress:"))
        let footerAt = try #require(body.range(of: "progressFooter"))
        #expect(glassAt.lowerBound < footerAt.lowerBound, "the footer moved inside the glass card")
        let footer = Self.slice(deck, from: "@ViewBuilder private var progressFooter", to: "private func nudgeAlertness")
        #expect(!footer.contains(".onboardingCard()") && !footer.contains(".glassEffect("))
        // Both download/warming branches are a fixed height, two-line captions.
        #expect(footer.components(separatedBy: ".frame(height: Self.footerHeight, alignment: .top)").count - 1 == 2)
        #expect(footer.components(separatedBy: ".lineLimit(2)").count - 1 == 2)
        // No live voice bar inside the glass card: only a static line there, the bar in its own slot.
        let voice = Self.slice(deck, from: "private var voiceCard", to: "private var faceCard")
        #expect(!voice.contains("ProgressView"), "a ticking Kokoro bar is inside the glass card")
        #expect(deck.contains("voiceLoadSlot"))
        let slot = Self.slice(deck, from: "private var voiceLoadSlot", to: "private var navigation")
        #expect(slot.contains("ProgressView(value: env.voiceLoad.fraction)") && slot.contains(".frame(height: 14)"))
        #expect(try glassAt.lowerBound < #require(body.range(of: "voiceLoadSlot")).lowerBound, "the voice slot moved inside the glass")
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
        #expect(deck.contains("guard !hasFinished"), "finish() lost its double-tap guard")
        #expect(deck.contains("fullDoor: fullDoor"), "the Private door would speak the sign-off")
        #expect(!deck.contains("try? await Task.sleep"), "a sleep swallows cancellation")
        let turn = Self.slice(deck, from: "private func turn(forward", to: "@ViewBuilder private var progressFooter")
        let engage = try #require(turn.range(of: "flow.engage()"))
        let early = try #require(turn.range(of: "guard forward"))
        #expect(engage.lowerBound < early.lowerBound, "Return on the last card no longer engages")
        #expect(hello.contains("chosenExperience = experience") && hello.contains("fullDoor: chosenExperience == .fullExperience"))
        #expect(hello.contains("minHeight: 700"))
    }

    // MARK: - The kit card (PR 2b: "My full kit")

    @Test("the kit card holds no ProgressView inside the glass; its live bar is in a fixed slot below it")
    func kitCardObeysTheGlassRule() throws {
        let deck = try Self.code("M1K3App/WakeSetupCarousel.swift")
        let card = Self.slice(deck, from: "private var kitCard", to: "private var kitLoadSlot")
        #expect(!card.contains("ProgressView("), "a ticking bar is inside the glass card")
        #expect(!card.contains(".glassEffect(") && !card.contains(".onboardingCard"))
        // Rows are a fixed height, so a status change never resizes the glass.
        #expect(card.contains(".frame(height: Self.kitRowHeight, alignment: .top)"))
        let slot = Self.slice(deck, from: "private var kitLoadSlot", to: "private var voiceLoadSlot")
        #expect(slot.contains("ProgressView(value: fraction)") && slot.contains(".frame(height: Self.kitSlotHeight)"))
        // The slot sits after the glass card in the body, never inside it.
        let body = Self.slice(deck, from: "var body: some View", to: "@ViewBuilder private var card")
        let glassAt = try #require(body.range(of: ".onboardingCard(nearLiveProgress:"))
        let slotAt = try #require(body.range(of: "kitLoadSlot"))
        #expect(glassAt.lowerBound < slotAt.lowerBound, "the kit slot moved inside the glass")
        // The row status is static copy from the pure kit, not a live view.
        #expect(card.contains("OnboardingKit.statusLine(row.status)"))
    }

    @Test("Get my kit reuses env.startDownload (no second download path) and the deck's Done never waits on it")
    func doneNeverWaitsOnTheKit() throws {
        let deck = try Self.code("M1K3App/WakeSetupCarousel.swift")
        let get = Self.slice(deck, from: "private func getKit", to: "private var kitLoadSlot")
        #expect(get.contains("env.startDownload(kind)"))
        #expect(!get.contains("await") && !get.contains("Task"), "the tap awaits a download")
        #expect(get.contains("soundEffects.play(.selectionTick)"))
        for path in ["switchEmbeddings", "enableWhisperKit", "prepareM1K3Voice", "BrainWeightsFetcher", "WhisperKit.download"] {
            #expect(!deck.contains(path), "\(path): the deck grew its own download path")
        }
        let finish = Self.slice(deck, from: "private func finish(", to: "private func sayHi")
        for forbidden in ["kit.", "downloadItems", "startDownload", "progress("] {
            #expect(!finish.contains(forbidden), "finish() looks at the kit (\(forbidden))")
        }
        #expect(finish.contains("onComplete()"))
        // The toggles tick like every other selection on the deck.
        let card = Self.slice(deck, from: "private var kitCard", to: "private var kitLoadSlot")
        #expect(card.contains("soundEffects.play(.selectionTick)"))
        #expect(card.contains("kit.toggle(item.kind)"))
    }

    @Test("the wait decks have no kit card; the no-wait deck does")
    func kitOnlyOnTheNoWaitDeck() throws {
        let hello = try Self.code("M1K3App/HelloView.swift")
        #expect(hello.contains("WakeSetupFlow(cards: WakeSetupCard.waitDeck)"))
        #expect(hello.contains("WakeSetupFlow(brainAlreadyReady: true)"))
        let deck = try Self.code("M1K3App/WakeSetupCarousel.swift")
        #expect(deck.contains("if flow.cards.contains(.kit) { kitLoadSlot }"))
        #expect(deck.contains("case .kit: kitCard"))
    }

    @Test("the brain picker and the upgrade card offer semantic memory through the one pure decision and the one verb")
    func semanticMemoryRidesWithTheBrain() throws {
        let picker = try Self.code("M1K3App/BrainPickerView.swift")
        #expect(picker.contains("SemanticMemoryOfferToggle(isOn: $alsoSemanticMemory)"))
        #expect(picker.contains("env.offersSemanticMemory(alongside: tier)"))
        #expect(picker.contains("env.startDownload(.semanticMemory)"))
        #expect(picker.contains("@State private var alsoSemanticMemory = SemanticMemoryOffer.preTicked"))

        let content = try Self.code("M1K3App/ContentView.swift")
        let card = Self.slice(content, from: "private struct BrainUpgradeNudgeCard", to: "private struct VoicePermissionBanner")
        #expect(card.contains("!isStagedSwitch && env.offersSemanticMemory(alongside: target)"), "a staged switch fetches nothing")
        #expect(card.contains("SemanticMemoryOfferToggle(isOn: $alsoSemanticMemory)"))
        #expect(content.contains("if alsoSemanticMemory { env.startDownload(.semanticMemory) }"))

        let env = try Self.code("M1K3App/AppEnvironment+Downloads.swift")
        #expect(env.contains("SemanticMemoryOffer.shouldOffer("))
        #expect(env.contains("downloadsLedger.scanned &&"), "the offer must wait for the first disk scan")
    }

    @Test("the Re-run button starts the onboarding stopwatch")
    func rerunButtonStartsTrace() throws {
        let code = try Self.code("M1K3App/Settings/GeneralSettingsPane.swift")
        #expect(code.contains("OnboardingTrace.shared.begin()"))
    }
}
