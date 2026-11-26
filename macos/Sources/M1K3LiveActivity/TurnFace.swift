//
//  TurnFace.swift
//  M1K3LiveActivity
//
//  M1K3's pixel face for the Live Activity: which cells of the 13x11 matrix are lit for each phase. The
//  matrix, eye cells and resting smile are COPIED from the screensaver's `PixelFace` (the widget
//  extension cannot link that module's package graph under its ~30 MB ceiling); TurnFaceTests pins the
//  copy against it. Static on purpose: a Live Activity does not animate freely, so the expression
//  carries the phase instead of a blink.
//
//  - thinking: eyes glancing aside, a flat mouth
//  - reading: eyes down on the page, a flat mouth
//  - answering: eyes open, mouth open (talking)
//  - ready: the resting face, exactly the screensaver's
//  - paused: eyes shut, a flat mouth
//  - listening: eyes up, a flat mouth (a voice conversation behind the lock, waiting)
//  - speaking: eyes open, the mouth wide (saying the answer aloud)
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.75 (cells pinned by test against PixelFace;
//  how each expression reads at Island size is verify-on-device), Prior: PixelFace (M1K3ScreensaverCore,
//  Kev + claude-opus-4-8, 2026-08-20), copied.
//  Review: Kev + claude-opus-5.5, 2026-11-26 — listening and speaking, for voice behind the lock. Confidence 0.75 (the look
//  at Island size is on the phone check).

import Foundation

public enum TurnFace {
    public struct Cell: Hashable, Sendable {
        public let col: Int
        public let row: Int
        public init(col: Int, row: Int) {
            self.col = col
            self.row = row
        }
    }

    public static let cols = 13
    public static let rows = 11
    public static let leftEye = Cell(col: 4, row: 3)
    public static let rightEye = Cell(col: 8, row: 3)
    public static let mouthRow = 7

    /// Every lit cell for the phase.
    public static func cells(for phase: TurnActivityPhase) -> Set<Cell> {
        switch phase {
        case .thinking: eyesOpen(dx: 1, dy: 0).union(flatMouth)
        case .reading: eyesOpen(dx: 0, dy: 1).union(flatMouth)
        case .answering: eyesOpen(dx: 0, dy: 0).union(openMouth)
        case .ready: eyesOpen(dx: 0, dy: 0).union(restingSmile)
        case .paused: eyesShut.union(flatMouth)
        case .listening: eyesOpen(dx: 0, dy: -1).union(flatMouth)
        case .speaking: eyesOpen(dx: 0, dy: 0).union(wideMouth)
        }
    }

    private static func eyesOpen(dx: Int, dy: Int) -> Set<Cell> {
        [
            Cell(col: leftEye.col + dx, row: leftEye.row + dy),
            Cell(col: rightEye.col + dx, row: rightEye.row + dy),
        ]
    }

    private static var eyesShut: Set<Cell> {
        var cells = Set<Cell>()
        for eye in [leftEye, rightEye] {
            for dc in -1 ... 1 {
                cells.insert(Cell(col: eye.col + dc, row: eye.row))
            }
        }
        return cells
    }

    private static var flatMouth: Set<Cell> {
        Set((4 ... 8).map { Cell(col: $0, row: mouthRow) })
    }

    private static var openMouth: Set<Cell> {
        var cells = Set<Cell>()
        for row in mouthRow ... mouthRow + 1 {
            for col in 5 ... 7 {
                cells.insert(Cell(col: col, row: row))
            }
        }
        return cells
    }

    /// Wider than `openMouth` by a column each side: speaking out loud, not words arriving on screen.
    private static var wideMouth: Set<Cell> {
        var cells = Set<Cell>()
        for row in mouthRow ... mouthRow + 1 {
            for col in 4 ... 8 {
                cells.insert(Cell(col: col, row: row))
            }
        }
        return cells
    }

    /// The screensaver's resting smile: the middle dips, each step out turns one row up.
    private static var restingSmile: Set<Cell> {
        var cells = Set<Cell>()
        for col in 3 ... 9 {
            let row = switch abs(col - 6) {
            case 3: mouthRow - 1
            case 2: mouthRow
            default: mouthRow + 1
            }
            cells.insert(Cell(col: col, row: row))
        }
        return cells
    }
}
