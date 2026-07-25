//
//  SidebarAutoCollapseTests.swift
//  M1K3PreviewTests
//
//  macOS NavigationSplitView does NOT auto-collapse the sidebar on a narrow
//  window (`.automatic` only adapts on iPhone/iPad size classes — the 07-14
//  comment claiming otherwise was wishful). This policy supplies the missing
//  behaviour as a pure transition machine: collapse on CROSSING below the
//  threshold, restore the user's preference on crossing back, and never let a
//  width-driven collapse clobber the persisted preference. An explicit toggle
//  while narrow is still honoured (the policy only reacts to width changes).
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.9, Prior: Unknown
//

import CoreGraphics
@testable import M1K3Preview
import Testing

struct SidebarAutoCollapseTests {
    private let t = SidebarAutoCollapse.threshold

    // MARK: - First layout (no previous width)

    @Test("first layout wide follows the preference")
    func firstLayoutWide() {
        #expect(SidebarAutoCollapse.transition(from: nil, to: t + 100, preferredVisible: true) == true)
        #expect(SidebarAutoCollapse.transition(from: nil, to: t + 100, preferredVisible: false) == false)
    }

    @Test("first layout narrow collapses regardless of preference")
    func firstLayoutNarrow() {
        #expect(SidebarAutoCollapse.transition(from: nil, to: t - 100, preferredVisible: true) == false)
        #expect(SidebarAutoCollapse.transition(from: nil, to: t - 100, preferredVisible: false) == false)
    }

    // MARK: - Crossing the threshold

    @Test("shrinking across the threshold collapses")
    func shrinkCollapses() {
        #expect(SidebarAutoCollapse.transition(from: t + 50, to: t - 1, preferredVisible: true) == false)
    }

    @Test("growing across the threshold restores the preference")
    func growRestores() {
        #expect(SidebarAutoCollapse.transition(from: t - 50, to: t + 1, preferredVisible: true) == true)
        #expect(SidebarAutoCollapse.transition(from: t - 50, to: t + 1, preferredVisible: false) == false)
    }

    @Test("exactly the threshold counts as wide")
    func thresholdIsWide() {
        #expect(SidebarAutoCollapse.transition(from: t - 10, to: t, preferredVisible: true) == true)
    }

    // MARK: - No crossing → no opinion (nil = leave state alone)

    @Test("resizing within the wide band is not a transition")
    func wideBandNoChange() {
        #expect(SidebarAutoCollapse.transition(from: t + 10, to: t + 300, preferredVisible: true) == nil)
    }

    @Test("resizing within the narrow band is not a transition — a manual re-open survives further shrinking")
    func narrowBandNoChange() {
        // The user explicitly re-opened the sidebar at 600pt; dragging to 550pt
        // must not slam it shut again.
        #expect(SidebarAutoCollapse.transition(from: t - 100, to: t - 150, preferredVisible: true) == nil)
    }

    // MARK: - Preference persistence rule

    @Test("explicit sets persist only when wide — narrow writes are transient")
    func persistenceRule() {
        #expect(SidebarAutoCollapse.persistsPreference(atWidth: t + 1))
        #expect(SidebarAutoCollapse.persistsPreference(atWidth: t))
        #expect(!SidebarAutoCollapse.persistsPreference(atWidth: t - 1))
        // Pre-layout (no width yet): trust the write — it can only come from
        // the user's own toggle.
        #expect(SidebarAutoCollapse.persistsPreference(atWidth: nil))
    }
}
