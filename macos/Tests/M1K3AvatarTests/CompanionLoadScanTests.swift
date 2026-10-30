//
//  CompanionLoadScanTests.swift
//  M1K3AvatarTests
//
//  Kev's iPhone round, 2026-10-30: fast switching in Settings left a creature stuck looping one
//  animation, and picking the Phosphor Fox often didn't reach the chat screen. CompanionAvatarView
//  lives in the app shell, out of `swift test`'s reach, so these are coarse tripwires over its
//  load path. What they cannot prove (whether the swap lands on a device) is a device check.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-30, Confidence 0.7 (string tripwires; the behaviour is
//  verify-by-launch). Prior: none (new file).
//

import Foundation
import Testing

struct CompanionLoadScanTests {
    private static func source() throws -> String {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("M1K3App/CompanionAvatarView.swift"), encoding: .utf8
        )
        #expect(!src.isEmpty, "scan read an empty file: CompanionAvatarView moved")
        return src
    }

    @Test("only a complete clip harvest reaches the process-wide cache")
    func cachesOnlyCompleteHarvest() throws {
        let src = try Self.source()
        #expect(!src.contains("if !harvested.isEmpty { CompanionClipCache"))
        #expect(src.contains("CompanionAssets.isComplete(harvested.keys, for: companion)"))
    }

    @Test("the harvest reads the load's target, not the view's current companion")
    func harvestTakesItsTarget() throws {
        #expect(try Self.source().contains("harvestClips(idleHost: host, for: companion)"))
    }

    @Test("a cancelled load gives its claim back, only while the claim is still its own")
    func cancelledLoadReleasesClaim() throws {
        let src = try Self.source()
        // A cancelled load can resume before its successor bumps the token, with the claim already
        // on the new target: releasing it unguarded re-triggers a switch (bot pass on #754).
        let release = "scene.loadedCompanionID = scene.displayedCompanion?.id"
        #expect(src.components(separatedBy: release).count == 3, "both release sites")
        #expect(src.components(separatedBy: "scene.loadedCompanionID == companion.id").count == 3)
    }

    @Test("iPhone: the keyboard goes down BEFORE the push: after it, this screen loses its keyboard avoidance")
    func chatDropsKeyboardBeforeLeaving() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("M1K3iOSApp/ChatScreen.swift"), encoding: .utf8)
        let dropped = try #require(chat.range(of: "inputFocused = false\n                        showSettings = true"))
        #expect(!dropped.isEmpty)
        #expect(chat.contains("inputFocused = false\n                        core.enterVoiceMode()"))
        // A NavigationLink pushes with no hook before the transition: that's how the bug got in.
        #expect(!chat.contains("NavigationLink {\n                        SettingsScreen()"))
    }

    @Test("a companion change doesn't wait on a RealityView update: the covered chat hero follows it")
    func changeIsObserved() throws {
        let src = try Self.source()
        #expect(src.contains(".onChange(of: companion.id)"))
        let appear = try #require(src.range(of: ".onAppear {"))
        let disappear = try #require(src.range(of: ".onDisappear {"))
        #expect(src[appear.upperBound ..< disappear.lowerBound].contains("claimSwitch()"))
    }
}
