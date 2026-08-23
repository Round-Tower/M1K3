//
//  PixelMark.swift
//  M1K3ScreensaverCore
//
//  The M1K3 "M" brand mark, as geometry the screensaver draws. The SAME 5×5
//  pixel map that drives the app icon (tools/icons/brand/build_m_mark.py) —
//  kept here as the single source of truth for the screensaver's hero glyph so
//  the mark can never drift between the icon and this surface.
//
//  Foundation-only + pure: the `.saver` bundle maps `cells(in:)`'s unit rects to
//  device pixels and strokes them. No CoreGraphics here, so the geometry is
//  testable without a drawing context.
//
//  Signed: Kev + claude-opus-4-8, 2026-08-20, Confidence 0.9 (the ON-map is the
//  wordmark's own M, verified against the compiled icon). Prior: the M mark
//  (PR #142, this session).
//  Review: Kev + claude-opus-4-8, 2026-08-23 — reduced 5×7 (17 cells) → 5×5
//  (13 cells): dropped two redundant leg-rows so the mark is square and reads
//  identically at small sizes, unified across macOS/iOS/visionOS/Android.
//

/// A rectangle in unit space (0…1 within a framing box), origin top-left.
public struct MarkCell: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum PixelMark {
    public static let columns = 5
    public static let rows = 5

    /// Which cells of the 5×5 grid are "on" — the pixel M:
    ///   █ · · · █
    ///   █ █ · █ █
    ///   █ · █ · █
    ///   █ · · · █
    ///   █ · · · █
    public static let onCells: [(col: Int, row: Int)] = [
        (0, 0), (4, 0),
        (0, 1), (1, 1), (3, 1), (4, 1),
        (0, 2), (2, 2), (4, 2),
        (0, 3), (4, 3),
        (0, 4), (4, 4),
    ]

    /// The mark's aspect ratio (width / height) — 5/5 = 1 (square). The saver
    /// uses this to fit the glyph without distortion.
    public static var aspectRatio: Double {
        Double(columns) / Double(rows)
    }

    /// The "on" cells as unit rectangles inside a `columns × rows` grid, with a
    /// seam between blocks. `gap` is the fraction of a cell left as the seam
    /// (0…0.5). Coordinates are normalised so the whole grid spans 0…1 on both
    /// axes — the caller scales to its framing box.
    public static func cells(gap: Double = 0.10) -> [MarkCell] {
        let g = max(0, min(gap, 0.5))
        let cw = 1.0 / Double(columns)
        let ch = 1.0 / Double(rows)
        let inset = g / 2
        return onCells.map { cell in
            MarkCell(
                x: Double(cell.col) * cw + inset * cw,
                y: Double(cell.row) * ch + inset * ch,
                width: cw * (1 - g),
                height: ch * (1 - g)
            )
        }
    }
}
