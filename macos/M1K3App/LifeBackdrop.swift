//
//  LifeBackdrop.swift
//  M1K3App
//
//  Conway's Game of Life as a quiet texture: every cell of the grid a faint
//  rounded square, the living ones lit (newborns brightest, old still-lifes
//  sinking back). It sits behind the Settings identity card — the "alive,
//  quietly" counterpart to the thinking rain — and the store frames port the
//  same field to JS.
//
//  Cheap by construction: a Canvas redrawn a few times a second from a pure
//  `LifeField` (M1K3ScreensaverCore, tested), stepped by a task that only runs
//  while the window is on screen and Reduce Motion is off (the #293 lesson:
//  nothing animates for nobody). Reduce Motion gets a still frame that has
//  already lived a few dozen generations, so it reads as life, not static.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-23, Confidence 0.8 (thin glue over a
//  tested field; density, pace and opacity are taste — verify-by-eye).
//  Prior: Unknown
//

import M1K3ScreensaverCore
import SwiftUI

struct LifeBackdrop: View {
    /// Grid pitch in points (cell + gap).
    var pitch: CGFloat = 16
    var tint: Color = .accentColor
    /// Scales every cell's opacity (1 = the house curve).
    var strength: Double = 1
    /// Seconds per generation.
    var interval: Double = 0.45
    var seed: UInt64 = 0x4D31_4B33

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowVisible) private var windowVisible
    @State private var field: LifeField?

    /// What the stepping task is keyed on: the grid's shape (a resize rebuilds)
    /// and whether anything should move.
    private struct Run: Equatable {
        let columns: Int
        let rows: Int
        let animates: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = Int((geometry.size.width / pitch).rounded(.up))
            let rows = Int((geometry.size.height / pitch).rounded(.up))
            // Read the field HERE, in body: a read inside the Canvas renderer
            // registers no dependency, so each generation would never redraw.
            let snapshot = field
            Canvas { context, _ in
                guard let field = snapshot else { return }
                let inset = max(1.5, pitch * 0.16)
                let side = pitch - inset * 2
                for row in 0 ..< field.rows {
                    for column in 0 ..< field.columns {
                        let rect = CGRect(
                            x: CGFloat(column) * pitch + inset,
                            y: CGFloat(row) * pitch + inset,
                            width: side, height: side
                        )
                        let alpha = Self.opacity(forAge: field.age(column: column, row: row)) * strength
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: side * 0.28),
                            with: .color(tint.opacity(alpha))
                        )
                    }
                }
            }
            // Build (or rebuild on a resize) and step in ONE task keyed on the
            // grid: it runs on appear, so the field can't be missed the way a
            // geometry-change callback can.
            .task(id: Run(columns: columns, rows: rows, animates: windowVisible && !reduceMotion)) {
                rebuild(columns: columns, rows: rows)
                guard windowVisible, !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    field?.advance()
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// Dead cells keep a whisper of the grid; newborns glow; age fades them
    /// toward a steady mid-tone so still-lifes don't dominate.
    static func opacity(forAge age: UInt8) -> Double {
        guard age > 0 else { return 0.05 }
        let fade = min(Double(age - 1) / 12, 1)
        return 0.5 - 0.3 * fade
    }

    private func rebuild(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        if let field, field.columns == columns, field.rows == rows { return }
        var fresh = LifeField(columns: columns, rows: rows, density: 0.22, seed: seed)
        // Let the soup settle into shapes before anyone sees it.
        for _ in 0 ..< 36 {
            fresh.advance()
        }
        field = fresh
    }
}
