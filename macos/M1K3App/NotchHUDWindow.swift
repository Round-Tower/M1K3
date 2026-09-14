//
//  NotchHUDWindow.swift
//  M1K3App
//
//  The floating narration pill: a borderless, click-through NSWindow docked
//  under the menu bar, shown only while M1K3 is talking. Promoted from
//  scratch/jam-2026-08-31-2314/notch-hud.swift, where every constant here was
//  proven live against a ground-truth WindowServer probe before landing —
//  see NotchHUDController for the visibility/animation gotchas this carries.
//
//  Signed: Kev + claude-fable-5, 2026-09-01, Confidence 0.85 (window plumbing
//  is byte-for-byte the jam's proven config; the SwiftUI content underneath
//  is new — verify-by-launch per this repo's convention for RealityKit/AppKit
//  glue). Prior: the jam prototype, same session.
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the root tracks window
//  visibility so the content can drop its RealityView while ordered out.
//  Confidence now 0.85.
//  Review: Kev + claude-fable-5.1, 2026-09-12 — `NotchHUDLayout.shape` (flat top, rounded bottom),
//  a zero gap under the menu bar and no hosting safe-area inset, so the panel hugs the notch.
//  Confidence 0.8.
//  Review: Kev + claude-opus-5, 2026-09-14 — the panel grew out of nothing: docked at
//  `visibleFrame.maxY` it hung BELOW the notch (Kev's screenshot). `NotchHUDPlacement` now puts the top
//  at the screen's top on a notched display, taller by the notch, content below it; the frame is
//  sized per screen and `constrainFrameRect` is a pass-through so AppKit can't push it under the
//  menu bar. Confidence 0.8 (verify-by-launch).
//

import AppKit
import M1K3Voice
import SwiftUI

/// Fixed layout — the SwiftUI root pins to this exact size (see
/// `NotchHUDContentView`) so `NSHostingView` has nothing to auto-resize the
/// window TO. Deriving from `contentView?.fittingSize` instead collapsed the
/// window to 0×0 in the jam: RealityKit/glassEffect content can report a
/// `.zero`-but-non-nil fitting size before it ever mounts on-screen.
/// Per-screen geometry the SwiftUI root reads: how tall the notch strip at
/// the top of the window is (0 when docked under a plain menu bar).
@MainActor @Observable
final class NotchHUDGeometry {
    var contentTopInset: CGFloat = 0
    var contentHeight: CGFloat = NotchHUDLayout.size.height
    /// The notch's width, so the panel can grow in from exactly the notch.
    var notchWidth: CGFloat = 0
    /// False while the panel is folded into the notch (before the grow-in,
    /// after the fold-out). Docked panels slide instead and stay true.
    var expanded = true
    var growsFromNotch: Bool {
        contentTopInset > 0
    }
}

enum NotchHUDLayout {
    static let size = NSSize(width: 460, height: 110)
    static let avatarSize: CGFloat = 72
    static let horizontalPadding: CGFloat = 28
    static let interItemSpacing: CGFloat = 16
    static let textAreaWidth: CGFloat = size.width - horizontalPadding * 2 - avatarSize - interItemSpacing
    /// The HUD layout under a notch: a bigger creature centred over the line.
    /// Wide, because the creatures are long, not tall: the aspect-aware fit
    /// makes them bigger in a wide slot without clipping the walk cycle.
    static let hudAvatarSlot = CGSize(width: 200, height: 116)
    static let hudTextWidth: CGFloat = size.width - horizontalPadding * 2
    /// 4 top + 116 creature + 6 + ~17 line + 6 + ~13 caption + 14 bottom, rounded up.
    static let hudContentHeight: CGFloat = 178
    /// Flat top (meets the menu bar / notch), rounded bottom corners.
    static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 0, bottomLeadingRadius: 28, bottomTrailingRadius: 28, topTrailingRadius: 0,
        style: .continuous
    )
}

@MainActor
final class NotchHUDWindow: NSWindow {
    let geometry = NotchHUDGeometry()

    init(env: AppEnvironment) {
        super.init(
            contentRect: NSRect(origin: .zero, size: NotchHUDLayout.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Ordinary `.statusBar` level reads as BELOW the real system menu bar
        // when the window's y-origin overlaps its screen rect — the OS paints
        // the menu bar over it regardless of level value (jam finding). The
        // margin here is deliberate, not load-bearing for the overlap itself
        // (targetOrigin already docks below visibleFrame).
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        let hosting = NSHostingView(
            rootView: NotchHUDContentView(env: env, geometry: geometry)
                .trackWindowVisibility()
        )
        // No safe-area inset: the hosting view must lay the panel out over
        // the WHOLE window or the flat top never meets the menu bar.
        hosting.safeAreaRegions = []
        contentView = hosting
        setContentSize(NotchHUDLayout.size)
        alphaValue = 0
    }

    /// Sizes the window for `screen` and returns where it shows: grown out of
    /// the notch on a notched display, docked under the menu bar otherwise
    /// (`NotchHUDPlacement`, unit-pinned).
    func targetOrigin(on screen: NSScreen) -> NSPoint {
        let placement = NotchHUDPlacement.place(
            panel: NotchHUDLayout.size,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            notchHeight: screen.safeAreaInsets.top,
            notchedContentHeight: NotchHUDLayout.hudContentHeight
        )
        geometry.contentTopInset = placement.contentTopInset
        geometry.contentHeight = placement.contentHeight
        let sides = (screen.auxiliaryTopLeftArea?.width ?? 0) + (screen.auxiliaryTopRightArea?.width ?? 0)
        geometry.notchWidth = placement.growsFromNotch ? max(0, screen.frame.width - sides) : 0
        setContentSize(placement.frame.size)
        return placement.frame.origin
    }

    /// AppKit nudges a window that overlaps the menu bar back under it; the
    /// panel's top is meant to sit in the notch, so take the frame as given.
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }

    /// Parked just above the shown position — the entrance slides down into place.
    func hiddenOrigin(shownAt shown: NSPoint) -> NSPoint {
        NSPoint(x: shown.x, y: shown.y + frame.height + 24)
    }
}
