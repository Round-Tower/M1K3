//
//  LookFrame.swift
//  M1K3Chat
//
//  The pure numbers behind a camera frame handed to a look (#768): the scale
//  that brings a sensor buffer down to what the spike measured (about 1,024 px
//  on the long edge, docs/evals/2026-11-09-vision-ttft-iphone/), the EXIF
//  orientation that stands it upright, and how many frames a just-opened camera
//  owes before its picture is worth reading. The capture is the shell's
//  (M1K3iOSApp/LookCamera.swift); these live here so `swift test` holds them.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.8, Prior: none (new file)
//  Open: eight settle frames is a guess at auto-exposure (about a quarter of a
//  second at 30 fps), not a measurement.
//

import Foundation

public enum LookFrame {
    /// The long edge a frame is scaled to before a brain reads it.
    public static let maxEdge = 1024

    /// Frames a camera delivers after opening before one is read: the first few
    /// are dark or blown out while exposure and white balance land.
    public static let settleFrames = 8

    /// How long a look waits for a settled frame before it takes what there is.
    public static let settleWait: Duration = .seconds(2)

    public static func settled(framesSeen: Int) -> Bool {
        framesSeen >= settleFrames
    }

    /// The factor that brings the long edge to `maxEdge`. Never above 1: a
    /// small frame is read as it is.
    public static func scale(width: Double, height: Double, maxEdge: Int = maxEdge) -> Double {
        let long = max(width, height)
        guard long > Double(maxEdge) else { return 1 }
        return Double(maxEdge) / long
    }

    /// The EXIF orientation (`CGImagePropertyOrientation` raw value) of a
    /// sensor buffer that needs `angle` degrees of clockwise rotation to stand
    /// upright, snapped to the nearest quarter turn: 0 up (1), 90 right (6),
    /// 180 down (3), 270 left (8).
    public static func exifOrientation(forRotationAngle angle: Double) -> UInt32 {
        let quarter = Int((angle / 90).rounded()) % 4
        switch (quarter + 4) % 4 {
        case 1: return 6
        case 2: return 3
        case 3: return 8
        default: return 1
        }
    }
}
