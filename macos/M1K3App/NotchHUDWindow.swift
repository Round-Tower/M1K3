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
//

import AppKit
import SwiftUI

/// Fixed layout — the SwiftUI root pins to this exact size (see
/// `NotchHUDContentView`) so `NSHostingView` has nothing to auto-resize the
/// window TO. Deriving from `contentView?.fittingSize` instead collapsed the
/// window to 0×0 in the jam: RealityKit/glassEffect content can report a
/// `.zero`-but-non-nil fitting size before it ever mounts on-screen.
enum NotchHUDLayout {
    static let size = NSSize(width: 460, height: 110)
    static let avatarSize: CGFloat = 72
    static let horizontalPadding: CGFloat = 28
    static let interItemSpacing: CGFloat = 16
    static let textAreaWidth: CGFloat = size.width - horizontalPadding * 2 - avatarSize - interItemSpacing
}

@MainActor
final class NotchHUDWindow: NSWindow {
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
            rootView: NotchHUDContentView(env: env)
                .frame(width: NotchHUDLayout.size.width, height: NotchHUDLayout.size.height)
        )
        contentView = hosting
        setContentSize(NotchHUDLayout.size)
        alphaValue = 0
    }

    /// Docked centred under the menu bar. `visibleFrame` (not `frame`) —
    /// `frame.maxY` overlaps the real menu bar's screen real estate and the
    /// OS paints over any ordinary window there (jam finding).
    func targetOrigin(on screen: NSScreen) -> NSPoint {
        let x = screen.frame.midX - NotchHUDLayout.size.width / 2
        let y = screen.visibleFrame.maxY - NotchHUDLayout.size.height - 4
        return NSPoint(x: x, y: y)
    }

    /// Parked just above the shown position — the entrance slides down into place.
    func hiddenOrigin(shownAt shown: NSPoint) -> NSPoint {
        NSPoint(x: shown.x, y: shown.y + NotchHUDLayout.size.height + 24)
    }
}
