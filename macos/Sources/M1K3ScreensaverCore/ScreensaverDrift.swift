//
//  ScreensaverDrift.swift
//  M1K3ScreensaverCore
//
//  The face's slow wander (#578): it sat in one place for hours. A Lissajous on two
//  incommensurate periods of minutes, so the path barely repeats; the box is small
//  enough that the face still reads as centred. Kinder to the panel, and it feels
//  alive. Units are fractions of the screen's shorter side.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.9 (pure, pinned in
//  ScreensaverMotionTests). Prior: none (new file).
//

import Foundation

public enum ScreensaverDrift {
    /// How far the face may wander each way, as a fraction of the shorter side.
    public static let amplitude = 0.04

    /// Where the face sits `seconds` into the run, relative to its home position.
    public static func offset(at seconds: Double) -> (dx: Double, dy: Double) {
        (amplitude * sin(2 * .pi * seconds / 113), amplitude * sin(2 * .pi * seconds / 157 + 1.3))
    }
}
