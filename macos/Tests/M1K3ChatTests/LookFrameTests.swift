//
//  LookFrameTests.swift
//  M1K3ChatTests
//
//  The camera frame's pure numbers (#768): how far a sensor buffer is scaled
//  before a brain reads it, which way up it is stood, and when a just-opened
//  camera's picture counts as settled. The capture itself is device work; these
//  are the parts a wrong constant would break silently (a sideways label, a
//  12 MP frame handed to a 4 GB phone).
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.85, Prior: none (new file)
//

@testable import M1K3Chat
import Testing

struct LookFrameTests {
    @Test("a 4K sensor frame comes down to 1,024 on its long edge")
    func scalesTheLongEdge() {
        #expect(LookFrame.scale(width: 3840, height: 2160) == 1024.0 / 3840.0)
        #expect(LookFrame.scale(width: 2160, height: 3840) == 1024.0 / 3840.0)
    }

    @Test("a frame already inside the cap is never blown up")
    func neverUpscales() {
        #expect(LookFrame.scale(width: 640, height: 480) == 1)
        #expect(LookFrame.scale(width: 1024, height: 768) == 1)
    }

    @Test("an empty buffer scales by one, not by infinity")
    func emptyBuffer() {
        #expect(LookFrame.scale(width: 0, height: 0) == 1)
    }

    @Test("the rotation angle picks the EXIF orientation that stands the frame up",
          arguments: [(0.0, 1), (90.0, 6), (180.0, 3), (270.0, 8), (360.0, 1), (-90.0, 8), (89.0, 6), (44.0, 1)])
    func orientation(_ angle: Double, _ exif: Int) {
        #expect(LookFrame.exifOrientation(forRotationAngle: angle) == UInt32(exif))
    }

    @Test("a camera that has only just opened is not settled: exposure is still moving")
    func settling() {
        #expect(!LookFrame.settled(framesSeen: 0))
        #expect(!LookFrame.settled(framesSeen: LookFrame.settleFrames - 1))
        #expect(LookFrame.settled(framesSeen: LookFrame.settleFrames))
    }
}
