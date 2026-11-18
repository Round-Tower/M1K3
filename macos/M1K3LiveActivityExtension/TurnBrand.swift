//
//  TurnBrand.swift
//  M1K3LiveActivityExtension
//
//  M1K3's look for the Live Activity: the pixel face as the mark, Silkscreen for the short labels, the
//  phosphor green and ink the brand already uses. The colours are the screensaver's (M1K3Screensaver:
//  `phosphor`, `inkTop`, `markColor`): the iOS app ships no AccentColor, so its tint is the system's, and
//  the brand lives in the face, the ink and the phosphor. Contrast on the ink: phosphor ~7.5:1, mark ~15:1,
//  the 72 % detail ~7:1 (all over the 4.5:1 floor).
//
//  Silkscreen follows PixelFont.swift's house rules: short app-written labels only, at 12 pt and up, fixed
//  size (a bitmap-style face scales fuzzy); the detail line stays system type so Dynamic Type works.
//  The face file ships in this extension and is registered at launch (UIAppFonts too): a font that fails to
//  load falls back silently, so `registerFonts` logs when it did not.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.65 (colours and sizes read off the app and the
//  screensaver; the rendered look, the font load and the compact-trailing fit are verify-on-device),
//  Prior: PixelFont.swift and M1K3ScreenSaverView.swift (the values), none for this file.
//  Review: Kev + claude-opus-5.5, 2026-11-17 — the face draws `copy.facePhase` (eyes shut on a stale card).

import CoreText
import M1K3LiveActivity
import os
import SwiftUI
import UIKit

enum TurnBrand {
    /// The phosphor green of the face and the working labels.
    static let phosphor = Color(red: 0.373, green: 0.816, blue: 0.659)
    /// The ink the card sits on (the screensaver's top ink; the Island itself is always black).
    static let ink = Color(red: 0.086, green: 0.086, blue: 0.102)
    /// Near-white for settled titles.
    static let mark = Color(red: 0.961, green: 0.961, blue: 0.969)
    /// The detail line: the mark at 72 %, as the screensaver sets its secondary line.
    static let detail = mark.opacity(0.72)

    static let pixelFamily = "Silkscreen"

    /// Silkscreen at a fixed size (the app's `.pixel(_:)`).
    static func pixel(_ size: CGFloat) -> Font {
        .custom(pixelFamily, fixedSize: size)
    }

    /// Register the bundled face for this process and say so if it did not take.
    static func registerFonts() {
        if let url = Bundle.main.url(forResource: "Silkscreen-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        // Both names: the PostScript name registration proves, and the FAMILY is what `Font.custom` renders with.
        let postScriptLoaded = UIFont(name: "Silkscreen-Regular", size: 12) != nil
        let familyLoaded = !UIFont.fontNames(forFamilyName: pixelFamily).isEmpty
        if !postScriptLoaded || !familyLoaded {
            Logger(subsystem: "app.m1k3", category: "liveactivity")
                .notice("Silkscreen did not load in the Live Activity; labels fall back to the system face")
        }
    }
}

/// The pixel face, drawn from `TurnFace`'s cells: static, one colour, crisp at any size.
struct TurnFaceMark: View {
    let copy: TurnActivityCopy

    var body: some View {
        Canvas { context, size in
            let cols = CGFloat(TurnFace.cols)
            let rows = CGFloat(TurnFace.rows)
            let unit = min(size.width / cols, size.height / rows)
            let origin = CGPoint(x: (size.width - unit * cols) / 2, y: (size.height - unit * rows) / 2)
            let ink = TurnBrand.phosphor
            for cell in TurnFace.cells(for: copy.facePhase) {
                let rect = CGRect(
                    x: origin.x + CGFloat(cell.col) * unit, y: origin.y + CGFloat(cell.row) * unit,
                    width: unit, height: unit
                )
                context.fill(Path(rect), with: .color(ink))
            }
        }
        .aspectRatio(CGFloat(TurnFace.cols) / CGFloat(TurnFace.rows), contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(copy.title)
        .accessibilityAddTraits(.isImage)
    }
}
