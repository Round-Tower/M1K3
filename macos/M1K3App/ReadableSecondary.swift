//
//  ReadableSecondary.swift
//  M1K3App
//
//  The colour for quiet text: captions, counts, timestamps, hints. SwiftUI's
//  `.secondary` measured 3.2:1 to 3.7:1 on this app's sidebar, lists and glass in
//  the light appearance (Xcode's accessibility audit on the Mac, 2026-11-14, each
//  finding re-measured on the screenshot), below the 4.5:1 that App Store
//  Connect's Sufficient Contrast label asks an app to meet by default. Primary at
//  this opacity keeps the text quieter than body copy and measures 5:1 or better on
//  the same surfaces in both appearances (the voice hint on its glass bubble was the
//  tightest, 4.8:1 in dark at 0.72, which is why this is 0.78); it follows the appearance, so dark mode gets white.
//
//  It is for TEXT: fills, dividers and tints keep `.secondary`, which needs 3:1, not
//  4.5:1. The 2026-11-14 sweep replaced every `.foregroundStyle(.secondary)`, so some
//  icons that shared a line with text moved too; that is harmless, and an icon whose
//  dimness IS its meaning (an off toggle) goes back to `.secondary` by hand.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-14, Confidence 0.7 (the ratio is measured
//  on seven Mac screens in light mode at one wallpaper; dark mode and the look
//  itself are Kev's eye), Prior: Unknown
//

import SwiftUI

extension Color {
    /// Quiet text that still clears 4.5:1 on the app's surfaces.
    static let readableSecondary = Color.primary.opacity(0.78)
}

extension ShapeStyle where Self == Color {
    /// Quiet text that still clears 4.5:1 on the app's surfaces.
    static var readableSecondary: Color {
        Color.readableSecondary
    }
}
