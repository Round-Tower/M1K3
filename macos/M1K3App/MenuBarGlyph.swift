//
//  MenuBarGlyph.swift
//  M1K3App
//
//  M1K3's status-bar mark. Drawn from a pixel grid (not an asset) so it stays
//  crisp at any menu-bar height and ships as a TEMPLATE image — macOS tints it
//  for light/dark + vibrancy. The "M" is the brand favicon reduced for the
//  smallest, most-seen surface: a 5×4 pixel M (peaks → shoulders → valley over
//  one leg-row) — the repeated second leg-row was cut as pure repetition. It
//  ships as THE glyph (the Settings picker was cut 2026-07-13, Kev-approved —
//  the pixel M is no longer a choice). The fuller 5×7 mark stays canonical in
//  M1K3ScreensaverCore.PixelMark (icon/screensaver/brand). `.pixelFace` + its
//  grid are kept as a rendering path (not deleted with the picker) even though
//  nothing calls it today — the smallest change that doesn't foreclose bringing
//  the face back. VERIFY-BY-LAUNCH: purely visual, judged by eye at ⌘R.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.7, Prior: Unknown
//  Review: Kev + claude-opus-4-8, 2026-08-23 — menu-bar M reduced 5×5 (13 lit)
//  → 5×4 (11 lit); bar-only, PixelMark untouched. Confidence 0.75 (verify-by-eye).

import AppKit

/// Which mark the menu-bar item shows.
enum MenuBarGlyphStyle: String, CaseIterable, Identifiable {
    case pixelM
    case pixelFace

    var id: String {
        rawValue
    }

    /// Pixel grid, top row first. "#" is a lit pixel, anything else is empty.
    var grid: [String] {
        switch self {
        case .pixelM:
            // The favicon's "M" reduced for the smallest surface: the second of
            // two identical leg-rows was pure repetition, so it's cut — leaving
            // peaks → shoulders → valley (the letter's identity) whole over a
            // single leg-row. Squarer and lighter in the bar than the 5×5 form,
            // still unmistakably M. The fuller 5×7 mark stays canonical in
            // PixelMark (icon/screensaver/brand); this variant is bar-only.
            ["#...#",
             "##.##",
             "#.#.#",
             "#...#"]
        case .pixelFace:
            // Two eyes + an upturned mouth — M1K3's pixel face, minimised.
            [".....",
             ".#.#.",
             ".....",
             "#...#",
             ".###."]
        }
    }

    /// Render the grid to a template NSImage sized to fit `pointSize` (the menu-
    /// bar height). Cells are floored to whole points so pixels stay sharp.
    /// `@MainActor`: `NSImage.lockFocus()` is main-thread-only. Memoised by
    /// (style, size) — the same glyph is asked for on every render pass, so the
    /// drawing context cost is paid once.
    @MainActor
    func image(pointSize: CGFloat = 16) -> NSImage {
        let cacheKey = "\(rawValue)@\(pointSize)"
        if let cached = Self.cache[cacheKey] { return cached }

        let rows = grid.count
        let cols = grid.map(\.count).max() ?? 0
        // Empty grid can't be drawn — lockFocus on a zero-dimension image is
        // undefined. The hardcoded grids never hit this; guard anyway.
        guard rows > 0, cols > 0 else { return NSImage() }
        let cell = max(1, (pointSize / CGFloat(max(rows, cols))).rounded(.down))
        let size = NSSize(width: cell * CGFloat(cols), height: cell * CGFloat(rows))

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        for (rowIndex, row) in grid.enumerated() {
            for (colIndex, char) in row.enumerated() where char == "#" {
                // NSImage origin is bottom-left; grid row 0 is the top row.
                NSRect(x: CGFloat(colIndex) * cell,
                       y: CGFloat(rows - 1 - rowIndex) * cell,
                       width: cell, height: cell).fill()
            }
        }
        image.unlockFocus()
        image.isTemplate = true // let macOS tint for light/dark menu bars
        Self.cache[cacheKey] = image
        return image
    }

    @MainActor private static var cache: [String: NSImage] = [:]
}
