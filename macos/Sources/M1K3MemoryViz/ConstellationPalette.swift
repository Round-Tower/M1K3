//
//  ConstellationPalette.swift
//  M1K3MemoryViz
//
//  Maps a node's hue (from ConstellationLayout.hue, kind-derived) to the colours
//  the view paints — a SwiftUI Color for any chrome and a platform Material.Color
//  for the RealityKit mote materials. Saturation/brightness are fixed here so the
//  field reads as one palette rather than a rainbow.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.8. Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-08 — `materialColor` gains its UIKit twin (UIColor) so iOS motes are
//  coloured like the Mac's. Confidence now 0.85.

import SwiftUI

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

public enum ConstellationPalette {
    /// Shared brightness so motes read as lit stars; hue + saturation vary per node
    /// (a plain note is near-white starlight; categorised kinds carry colour).
    static let brightness: CGFloat = 1.0

    public static func color(forHue hue: Float, saturation: Float) -> Color {
        Color(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness))
    }

    #if canImport(AppKit)
        /// RealityKit's `Material.Color` is `NSColor` on macOS — what
        /// `UnlitMaterial(color:)` wants for a glowing mote.
        public static func materialColor(forHue hue: Float, saturation: Float) -> NSColor {
            NSColor(hue: CGFloat(hue), saturation: CGFloat(saturation), brightness: brightness, alpha: 1.0)
        }

    #elseif canImport(UIKit)
        /// …and `UIColor` on iOS / visionOS — the same lit-star hue, so the
        /// iPad field is coloured like the Mac's, not the white it fell back to.
        public static func materialColor(forHue hue: Float, saturation: Float) -> UIColor {
            UIColor(hue: CGFloat(hue), saturation: CGFloat(saturation), brightness: brightness, alpha: 1.0)
        }
    #endif
}
