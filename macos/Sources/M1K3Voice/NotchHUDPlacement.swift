//
//  NotchHUDPlacement.swift
//  M1K3Voice
//
//  Where the notch HUD's window goes. On a notched screen the panel grows OUT
//  of the notch: its top meets the top of the screen and it is taller by the
//  notch's height, with the content laid out below that strip. It used to
//  dock at `visibleFrame.maxY`, under the menu bar, which left it hanging
//  below the notch as a separate pill (Kev's screenshot, 2026-09-14). A screen
//  with no notch keeps that docked placement: growing out of a plain menu bar
//  reads as a banner, not a notch.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85 (pure geometry,
//  pinned; the window has to sit at a level the OS paints over the menu bar,
//  and that part is verify-by-launch). Prior: Unknown
//

import CoreGraphics

public enum NotchHUDPlacement {
    public struct Placement: Equatable, Sendable {
        /// The window's frame in screen coordinates.
        public let frame: CGRect
        /// Height of the top strip the notch occupies; the content goes below it.
        public let contentTopInset: CGFloat
        /// True when the panel extends the notch rather than docking under the menu bar.
        public var growsFromNotch: Bool {
            contentTopInset > 0
        }
    }

    /// - Parameter notchHeight: `NSScreen.safeAreaInsets.top`, which is 0 on a screen without a notch.
    public static func place(
        panel: CGSize, screenFrame: CGRect, visibleFrame: CGRect, notchHeight: CGFloat
    ) -> Placement {
        let x = screenFrame.midX - panel.width / 2
        guard notchHeight > 0 else {
            return Placement(
                frame: CGRect(x: x, y: visibleFrame.maxY - panel.height, width: panel.width, height: panel.height),
                contentTopInset: 0
            )
        }
        let height = panel.height + notchHeight
        return Placement(
            frame: CGRect(x: x, y: screenFrame.maxY - height, width: panel.width, height: height),
            contentTopInset: notchHeight
        )
    }
}
