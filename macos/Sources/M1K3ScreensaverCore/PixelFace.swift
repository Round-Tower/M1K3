//
//  PixelFace.swift
//  M1K3ScreensaverCore
//
//  M1K3's face for the screensaver — a compact pixel matrix that lights the
//  right cells to "draw" two eyes and a soft resting smile, blinking and
//  glancing like the app's face (M1K3Avatar.FaceGrid / FaceExpression). It
//  mirrors that grid's proportions EXACTLY (13×11, eyes at (4,3)/(8,3), mouth
//  row 7 across cols 3…9) so the screensaver reads as the same character — but
//  it's reimplemented here, pure and self-contained, because M1K3Avatar ships a
//  RealityKit-companion resource bundle too heavy for a sandboxed .saver, and
//  the app's actual render IS RealityKit (hostile in a screensaver process).
//
//  The expression is deliberately calm — this is M1K3 at rest, keeping watch —
//  so there's one resting mood: open eyes with an occasional blink and a gentle
//  idle glance, and a settled smile. Pure + deterministic (time in, cells out),
//  so a test pins the blink window and the smile shape without a drawing context.
//
//  Signed: Kev + claude-opus-4-8, 2026-08-20, Confidence 0.85 (pure, TDD'd; the
//  felt life — blink cadence, glance — is verify-by-eye on the surface). Prior:
//  FaceGrid/FaceExpression (M1K3Avatar), the screensaver core (this session).
//

import Foundation

/// A cell in the face matrix (origin top-left; col increases right, row down).
public struct FaceCell: Hashable, Sendable {
    public let col: Int
    public let row: Int
    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
}

public enum PixelFace {
    public static let cols = 13
    public static let rows = 11

    public static let leftEye = FaceCell(col: 4, row: 3)
    public static let rightEye = FaceCell(col: 8, row: 3)
    public static let mouthRow = 7

    // Blink: closed for a blink flick at the tail of each period.
    private static let blinkPeriod: Double = 4.2
    private static let blinkDuration: Double = 0.16
    // Glance: a one-cell sideways dart, briefly, on its own slow cycle.
    private static let glancePeriod: Double = 5.3
    private static let glanceDuration: Double = 0.5

    /// True while the eyes are mid-blink (closed).
    public static func isBlinking(at time: Double) -> Bool {
        let t = time.truncatingRemainder(dividingBy: blinkPeriod)
        return t >= blinkPeriod - blinkDuration
    }

    /// The idle glance offset in cols: 0 at rest, ±1 during a brief dart. The
    /// direction alternates each glance so the eyes don't always look the same way.
    public static func glanceOffset(at time: Double) -> Int {
        // Fire in the TAIL of each period (like the blink) so t=0 is centred rest,
        // not mid-glance — the face opens looking straight ahead.
        let phase = time.truncatingRemainder(dividingBy: glancePeriod)
        guard phase >= glancePeriod - glanceDuration else { return 0 }
        let index = Int((time / glancePeriod).rounded(.down))
        return index.isMultiple(of: 2) ? 1 : -1
    }

    /// Every lit cell of the face at `time` — the two eyes (or the closed blink
    /// lines) plus the resting smile. What the `.saver` glows.
    public static func litCells(at time: Double) -> Set<FaceCell> {
        var cells = eyeCells(at: time)
        cells.formUnion(smileCells())
        return cells
    }

    // MARK: - Eyes

    private static func eyeCells(at time: Double) -> Set<FaceCell> {
        if isBlinking(at: time) {
            // Closed: a flat 3-cell line at each eye's row.
            var closed = Set<FaceCell>()
            for anchor in [leftEye, rightEye] {
                for dc in -1 ... 1 {
                    closed.insert(FaceCell(col: anchor.col + dc, row: anchor.row))
                }
            }
            return closed
        }
        // Open: a single pupil per eye, shifted by the idle glance.
        let dx = glanceOffset(at: time)
        return [
            FaceCell(col: leftEye.col + dx, row: leftEye.row),
            FaceCell(col: rightEye.col + dx, row: rightEye.row),
        ]
    }

    // MARK: - Mouth (a settled smile: corners turned up one row)

    private static func smileCells() -> Set<FaceCell> {
        // A gentle ⌣: the middle dips to the mouth row, stepping up one row for
        // each cell out to the corners — a connected, warm upturn. Distance from
        // the centre column (6) sets the row.
        var mouth = Set<FaceCell>()
        for col in 3 ... 9 {
            let dc = abs(col - 6)
            let row: Int
            switch dc {
            case 3: row = mouthRow - 1 // cols 3, 9 — corners highest
            case 2: row = mouthRow // cols 4, 8
            default: row = mouthRow + 1 // cols 5, 6, 7 — middle lowest
            }
            mouth.insert(FaceCell(col: col, row: row))
        }
        return mouth
    }
}
