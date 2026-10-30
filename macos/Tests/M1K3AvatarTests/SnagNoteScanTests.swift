//
//  SnagNoteScanTests.swift
//  M1K3AvatarTests
//
//  Source-scan tripwires for #750's shell wiring, the FieldReportScanTests idiom. The pure halves
//  (SessionGuard, SnagReport, the rating quiet window) are unit-pinned where they live; what these
//  hold is the glue no unit test can reach: the mark is set only on the UI launch path and cleared
//  only by a clean end, Debug builds leave the live mark alone unless asked, the note is withheld
//  from the bands #708's offer is withheld from, a snag feeds the rating ask's quiet window, and
//  the report goes through #708's one sheet and its one Send button.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.6 (coarse tripwires over text; the
//  banner, the sheet and a kill -9 relaunch are verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-29 (pre-push review fold) — pins the Release branch (always marks), the
//  iPhone app struct owning the mark (set before AppCore, cleared before the brain is shed), both drafts through
//  the scrub and the canary pass, the Mac sheet's snag kind, and visionOS-safe glass. Confidence 0.65.
//  Review: Kev + claude-opus-5.5, 2026-10-30 — pins the banner out of the window's sizing and the root's floor at
//  chatDetail's 520 (the overflow Kev found on the Mac check). Confidence 0.65.
//

import Foundation
import Testing

struct SnagNoteScanTests {
    private static var root: URL {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Source with comment lines stripped, so headers may explain what is kept out.
    private static func code(_ relative: String) throws -> String {
        let src = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(!src.isEmpty, "scan read an empty file — \(relative) moved")
        return src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The body of the first `func <name>` in `source`, up to the next `func `.
    private static func body(of name: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: "func \(name)"), "\(name) moved")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        return rest[..<end]
    }

    @Test("Mac: the mark is set on the UI launch path only, and cleared only by a clean quit")
    func macMarksTheUILaunchAndClearsOnQuit() throws {
        let app = try Self.code("M1K3App/M1K3App.swift")
        let launch = try Self.body(of: "applicationDidFinishLaunching", in: app)
        let selfTest = try #require(launch.range(of: "guard !SelfTest.isRequested"))
        let begin = try #require(launch.range(of: "sessionGuard.begin()"))
        #expect(begin.lowerBound > selfTest.upperBound, "a self-test run never marks a session")
        #expect(launch.contains("noteUncleanExit(openedAt:"))
        let quit = try Self.body(of: "applicationShouldTerminate", in: app)
        #expect(quit.contains("sessionGuard.end()"))
        #expect(app.components(separatedBy: "sessionGuard.end()").count == 2, "nothing else clears the mark")
    }

    @Test("Debug builds leave the live mark alone unless argv arms them; the screengrab harness never marks")
    func debugAndHarnessAreInert() throws {
        try Self.expectInertOnlyWhenAsked(Self.code("M1K3App/AppEnvironment+Snag.swift"))
    }

    @Test("a snag holds the rating ask, whatever the age band")
    func snagFeedsTheQuietWindow() throws {
        let snag = try Self.code("M1K3App/AppEnvironment+Snag.swift")
        let note = try Self.body(of: "noteUncleanExit", in: snag)
        #expect(note.contains("reviewLedger.recordCrash(at:"))
        #expect(!note.contains("fieldReportAllowed"), "the quiet window is not age-gated; only the offer is")
    }

    @Test("Mac: the banner is age-gated, has its own inset, and hands off to #708's sheet")
    func macBannerUsesTheFieldReportSheet() throws {
        let content = try Self.code("M1K3App/ContentView.swift")
        let banner = try #require(content.range(of: "SnagBanner("))
        let before = content[..<banner.lowerBound]
        let inset = try #require(before.range(of: ".safeAreaInset(edge: .top", options: .backwards))
        #expect(before[inset.upperBound...].contains("fieldReportAllowed"), "withheld from under-16 bands")
        #expect(!before[inset.upperBound...].contains("else if"), "its own inset, not a link in the banner chain")
        let after = content[banner.upperBound...]
        let draft = try #require(after.range(of: "FieldReporter.snagDraft("))
        let cleared = try #require(after.range(of: "env.snag = nil"))
        #expect(draft.lowerBound < cleared.lowerBound, "the draft is built before the note is cleared")
        #expect(!content.contains("SnagReportFormatter"), "the reporter builds the body, not the view")
    }

    @Test("Mac: the banner never sizes the window, and the window's floor fits the chat's")
    func bannerLeavesTheWindowAlone() throws {
        let content = try Self.code("M1K3App/ContentView.swift")
        let start = try #require(content.range(of: "private struct SnagBanner"))
        let end = try #require(content.range(of: "private struct VoiceUpgradeBanner"))
        // `.windowResizability(.contentSize)` measures the root at a narrow width: a vertically fixed
        // line wraps to a column there, and its height inflated the split view from 912 to 1,530 pt in a
        // 964 pt window, off both edges with the composer. VoiceUpgradeBanner never had the modifier.
        #expect(!content[start.lowerBound ..< end.lowerBound].contains("fixedSize"))
        // chatDetail's floor is 520: a 480 root clipped the composer 40 pt at the window's smallest.
        #expect(!content.contains(".frame(minWidth: 480, minHeight: 480)"))
        #expect(content.contains(".frame(minWidth: 480, minHeight: 520)"))
    }

    @Test("iPhone: the app owns the mark, sets it before AppCore builds, and clears it first on background")
    func iosMarksTheActiveScene() throws {
        let app = try Self.code("M1K3iOSApp/M1K3iOSHarnessApp.swift")
        let background = try #require(app.range(of: "case .background:"))
        let afterBackground = app[background.upperBound...]
        let end = try #require(afterBackground.range(of: "sessionGuard.end()"))
        let shed = try #require(afterBackground.range(of: "exitVoiceMode()"))
        #expect(end.lowerBound < shed.lowerBound, "cleared before the brain is shed, so a kill then is no snag")
        let active = try #require(app.range(of: "case .active:"))
        #expect(app[active.upperBound...].prefix(120).contains("markSessionActive()"))
        let boot = try Self.body(of: "boot", in: app)
        let live = try #require(boot.range(of: "UIApplication.shared.applicationState == .active"))
        let build = try #require(boot.range(of: "AppCore()"))
        #expect(live.lowerBound < build.lowerBound, "marked before the heavy build; a background launch waits")
        #expect(boot.contains("noteUncleanExit(openedAt:"), "a mark found before the core existed is handed over")
        let mark = try Self.body(of: "markSessionActive", in: app)
        #expect(mark.contains("sessionGuard.begin()"))
        #expect(app.components(separatedBy: "sessionGuard.end()").count == 2, "nothing else clears the mark")
        let core = try Self.code("M1K3iOSApp/AppCore+Snag.swift")
        try Self.expectInertOnlyWhenAsked(core)
        #expect(core.contains("reviewLedger.recordCrash(at:"))
    }

    @Test("both shells build the snag draft through the unit-pinned scrub and the canary pass")
    func snagDraftsAreRedacted() throws {
        let mac = try Self.body(of: "snagDraft", in: Self.code("M1K3App/FieldReporter.swift"))
        let ios = try Self.body(of: "snagDraft", in: Self.code("M1K3iOSApp/AppCore+Snag.swift"))
        for draft in [mac, ios] {
            #expect(draft.contains("SnagReportFormatter.redactedBody("))
            #expect(draft.contains("CanaryGuard.fromLocalConfig()"))
            #expect(!draft.contains("SnagReportFormatter.body("), "no unscrubbed body reaches a sheet")
        }
        #expect(mac.contains("FieldReportDraft(kind: .snag"), "the Mac sheet shows the snag wording")
        let sheet = try Self.code("M1K3App/FieldReportSheet.swift")
        let snagCase = try #require(sheet.range(of: "case .snag:"))
        #expect(sheet[snagCase.upperBound...].contains("Nothing you typed"))
    }

    /// The guard is inert under the harness and in Debug unless argv arms it, and LIVE in Release:
    /// a stray `return true` would kill #750 in every shipped build and pass the other checks.
    private static func expectInertOnlyWhenAsked(_ source: String) throws {
        let inert = try #require(source.range(of: "static var sessionGuardInert"))
        let after = source[inert.upperBound...]
        #expect(after.contains("ScreengrabHarness.current.isActive"))
        let debug = try #require(after.range(of: "#if DEBUG"))
        let release = try #require(after.range(of: "#else"))
        #expect(after[debug.upperBound ..< release.lowerBound].contains("\"armSessionGuard\""))
        let releaseBranch = after[release.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(releaseBranch.hasPrefix("return false"), "Release builds always mark")
    }

    @Test("iPhone: the card is age-gated and only the sheet's Send button mails, once")
    func iosCardAndSheet() throws {
        let host = try Self.code("M1K3iOSApp/SnagNoteHost.swift")
        let card = try #require(host.range(of: "SnagNoteCard("))
        let before = host[..<card.lowerBound]
        #expect(before.contains("AgeAppropriateness.fieldReportAllowed(for:"), "withheld from under-16 bands")
        #expect(host.components(separatedBy: "SnagMailer.send(").count == 2, "exactly one send")
        let sendButton = try #require(host.range(of: "Button(\"Send by email\")"))
        let call = try #require(host.range(of: "SnagMailer.send("))
        #expect(call.lowerBound > sendButton.upperBound, "the call sits inside the Send button")
        #expect(host.contains(".keyboardShortcut(sent ? nil : .defaultAction)") || !host.contains(".keyboardShortcut("))
        #expect(host.contains(".disabled(isBlank)"))
        #expect(!host.contains(".glassEffect("), "visionOS has no glassEffect: GlassCompat's m1k3Glass")
        let glassStyle = try #require(host.range(of: ".glassProminent"))
        let beforeStyle = host.startIndex ..< glassStyle.lowerBound
        let visionGuard = try #require(host.range(of: "#if os(visionOS)", options: .backwards, range: beforeStyle))
        let guarded = host[visionGuard.upperBound ..< glassStyle.lowerBound]
        #expect(guarded.contains("#else"), "glass styles only off visionOS")
        let root = try Self.code("M1K3iOSApp/RootView.swift")
        #expect(root.contains(".modifier(SnagNoteHost())"), "the host hangs off the chat screen")
        for path in try Self.iosFiles() where path != "M1K3iOSApp/SnagMailer.swift" {
            let src = try Self.code(path)
            #expect(!src.contains("MailtoURL"), "\(path) builds a mail link")
            #expect(!src.contains("mailto:"), "\(path) names mailto")
        }
    }

    /// Every Swift file under the mobile shell, relative to `macos/`.
    private static func iosFiles() throws -> [String] {
        let shell = root.appendingPathComponent("M1K3iOSApp")
        let walker = try #require(FileManager.default.enumerator(atPath: shell.path))
        return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { "M1K3iOSApp/" + $0 }.sorted()
    }
}
