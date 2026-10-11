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
        #expect(code.contains(".task {"), "AFM availability should be read in a .task")
        #expect(code.contains("backdropReady"), "the backdrop should mount after the card is visible")
    }

    @Test("the Re-run button starts the onboarding stopwatch")
    func rerunButtonStartsTrace() throws {
        let code = try Self.code("M1K3App/Settings/GeneralSettingsPane.swift")
        #expect(code.contains("OnboardingTrace.shared.begin()"))
    }
}
