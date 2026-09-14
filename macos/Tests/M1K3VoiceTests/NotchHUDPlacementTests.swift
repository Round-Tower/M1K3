//
//  NotchHUDPlacementTests.swift
//  M1K3VoiceTests
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.9 (pure geometry; the
//  notch height is what NSScreen.safeAreaInsets.top reports). Prior: Unknown
//

import CoreGraphics
@testable import M1K3Voice
import Testing

struct NotchHUDPlacementTests {
    // A 14" MacBook Pro: 1512×982 points, a 37 pt menu bar the notch sits in.
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
    let panel = CGSize(width: 460, height: 110)

    @Test("on a notched screen the window's top meets the top of the screen")
    func notchedTopIsFlush() {
        let p = NotchHUDPlacement.place(panel: panel, screenFrame: screen, visibleFrame: visible, notchHeight: 37)
        #expect(p.frame.maxY == screen.maxY)
    }

    @Test("on a notched screen the panel grows by the notch and the content sits below it")
    func notchedGrowsByNotch() {
        let p = NotchHUDPlacement.place(panel: panel, screenFrame: screen, visibleFrame: visible, notchHeight: 37)
        #expect(p.frame.height == 147)
        #expect(p.contentTopInset == 37)
        #expect(p.growsFromNotch)
        // The content's bottom edge lands where it did before: under the menu bar.
        #expect(p.frame.minY == visible.maxY - panel.height)
    }

    @Test("the panel is centred on the screen, where the notch is")
    func centred() {
        let p = NotchHUDPlacement.place(panel: panel, screenFrame: screen, visibleFrame: visible, notchHeight: 37)
        #expect(p.frame.midX == screen.midX)
    }

    @Test("a screen without a notch keeps the panel docked under the menu bar")
    func noNotchDocksUnderMenuBar() {
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let externalVisible = CGRect(x: 1512, y: 0, width: 2560, height: 1415)
        let p = NotchHUDPlacement.place(
            panel: panel, screenFrame: external, visibleFrame: externalVisible, notchHeight: 0
        )
        #expect(p.frame.maxY == externalVisible.maxY)
        #expect(p.frame.size == panel)
        #expect(p.contentTopInset == 0)
        #expect(!p.growsFromNotch)
        #expect(p.frame.midX == external.midX)
    }

    @Test("a hidden menu bar (visible frame reaches the top) still grows from the notch")
    func autoHiddenMenuBar() {
        let p = NotchHUDPlacement.place(panel: panel, screenFrame: screen, visibleFrame: screen, notchHeight: 37)
        #expect(p.frame.maxY == screen.maxY)
        #expect(p.contentTopInset == 37)
        #expect(p.frame.height == 147)
    }
}
