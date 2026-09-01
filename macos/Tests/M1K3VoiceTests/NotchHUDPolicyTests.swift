//
//  NotchHUDPolicyTests.swift
//  M1K3VoiceTests
//
//  Pins the notch HUD's debounce (Kokoro's own `speaking` flag genuinely flaps
//  true/false every ~150-300ms BETWEEN spoken sentences — the jam prototype
//  discovered this live; a naive edge-triggered show/hide reads as permanently
//  mid-fade) and the marquee travel/duration math, both proven first in
//  scratch/jam-2026-08-31-2314/notch-hud.swift.
//

import Foundation
@testable import M1K3Voice
import Testing

struct NotchHUDVisibilityTests {
    @Test("the first true reports a show action")
    func firstSpeakingShows() {
        var visibility = NotchHUDVisibility()
        let action = visibility.update(speaking: true, atSeconds: 0)
        #expect(action == .show)
        #expect(visibility.isShown)
    }

    @Test("a repeat true while already shown is a no-op")
    func repeatTrueIsNoop() {
        var visibility = NotchHUDVisibility()
        _ = visibility.update(speaking: true, atSeconds: 0)
        let action = visibility.update(speaking: true, atSeconds: 0.1)
        #expect(action == nil)
        #expect(visibility.isShown)
    }

    @Test("a brief false gap (shorter than the grace) between sentences does not hide")
    func briefGapDoesNotHide() {
        var visibility = NotchHUDVisibility(hideGraceSeconds: 0.7)
        _ = visibility.update(speaking: true, atSeconds: 0)
        // Kokoro's real flap shape: false for ~150-300ms, then true again.
        let midGap = visibility.update(speaking: false, atSeconds: 0.2)
        let resumed = visibility.update(speaking: true, atSeconds: 0.25)
        #expect(midGap == nil)
        #expect(resumed == nil) // still shown throughout — never dipped
        #expect(visibility.isShown)
    }

    @Test("false held past the grace window hides")
    func sustainedFalseHides() {
        var visibility = NotchHUDVisibility(hideGraceSeconds: 0.7)
        _ = visibility.update(speaking: true, atSeconds: 0)
        _ = visibility.update(speaking: false, atSeconds: 0.1)
        let action = visibility.update(speaking: false, atSeconds: 0.9)
        #expect(action == .hide)
        #expect(!visibility.isShown)
    }

    @Test("false while already hidden is a no-op")
    func falseWhileHiddenIsNoop() {
        var visibility = NotchHUDVisibility()
        let action = visibility.update(speaking: false, atSeconds: 0)
        #expect(action == nil)
        #expect(!visibility.isShown)
    }

    @Test("re-speaking after a hide shows again fresh")
    func reSpeakingAfterHideShowsAgain() {
        var visibility = NotchHUDVisibility(hideGraceSeconds: 0.7)
        _ = visibility.update(speaking: true, atSeconds: 0)
        _ = visibility.update(speaking: false, atSeconds: 0.1)
        _ = visibility.update(speaking: false, atSeconds: 0.9) // hides
        let action = visibility.update(speaking: true, atSeconds: 5)
        #expect(action == .show)
        #expect(visibility.isShown)
    }

    @Test("the grace clock resets on every fresh false — a second short gap doesn't inherit the first's elapsed time")
    func graceClockResetsPerGap() {
        var visibility = NotchHUDVisibility(hideGraceSeconds: 0.7)
        _ = visibility.update(speaking: true, atSeconds: 0)
        _ = visibility.update(speaking: false, atSeconds: 0.5) // gap starts
        _ = visibility.update(speaking: true, atSeconds: 0.6) // resumes before grace elapses
        // A second gap starting fresh at t=1.0 must need its OWN 0.7s, not
        // inherit time already spent in the first gap.
        let stillShown = visibility.update(speaking: false, atSeconds: 1.0)
        #expect(stillShown == nil)
        #expect(visibility.isShown)
    }
}

struct MarqueeMetricsTests {
    @Test("text that already fits the viewport needs no scrolling")
    func fittingTextDoesNotScroll() {
        #expect(MarqueeMetrics.plan(textWidth: 200, viewportWidth: 300) == nil)
    }

    @Test("text exactly as wide as the viewport needs no scrolling")
    func exactFitDoesNotScroll() {
        #expect(MarqueeMetrics.plan(textWidth: 300, viewportWidth: 300) == nil)
    }

    @Test("overflowing text scrolls the overflow plus a small trailing pad")
    func overflowingTextScrolls() throws {
        let plan = try #require(MarqueeMetrics.plan(textWidth: 500, viewportWidth: 300, pointsPerSecond: 50))
        #expect(plan.travel == 216) // (500 - 300) + 16pt trailing pad
        #expect(plan.duration == 216.0 / 50)
    }

    @Test("a non-positive scroll speed refuses to plan rather than divide by zero")
    func nonPositiveSpeedRefuses() {
        #expect(MarqueeMetrics.plan(textWidth: 500, viewportWidth: 300, pointsPerSecond: 0) == nil)
        #expect(MarqueeMetrics.plan(textWidth: 500, viewportWidth: 300, pointsPerSecond: -10) == nil)
    }
}
