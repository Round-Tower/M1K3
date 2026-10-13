//
//  ScreensaverMotionTests.swift
//  M1K3ScreensaverCoreTests
//
//  #578: every monitor showed the same rain (one fixed seed), and the face sat in
//  one place for hours. Each display now seeds its own rain, stable across runs,
//  and the face drifts slowly inside a small box: kinder to the panel, and alive.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.9 (pure). Prior: none (new file).
//

import M1K3ScreensaverCore
import Testing

struct ScreensaverMotionTests {
    @Test("each display gets its own rain, and the same display keeps it")
    func perScreenSeed() {
        let first = RainField.seed(forDisplay: 1)
        let second = RainField.seed(forDisplay: 2)
        #expect(first != second)
        #expect(RainField.seed(forDisplay: 1) == first)
        #expect(first != 0 && second != 0)
        let a = RainField(columns: 20, seed: first)
        let b = RainField(columns: 20, seed: second)
        #expect(a.drops != b.drops)
    }

    @Test("the face drifts within its box, a hair per frame, and does move over minutes")
    func drift() {
        let frame = 1.0 / 30.0
        var t = 0.0
        while t < 3600 {
            let here = ScreensaverDrift.offset(at: t)
            #expect(abs(here.dx) <= ScreensaverDrift.amplitude && abs(here.dy) <= ScreensaverDrift.amplitude)
            let next = ScreensaverDrift.offset(at: t + frame)
            #expect(abs(next.dx - here.dx) < 0.001 && abs(next.dy - here.dy) < 0.001, "no visible jump at \(t)")
            t += 7.3
        }
        let start = ScreensaverDrift.offset(at: 0)
        let later = ScreensaverDrift.offset(at: 600)
        #expect(abs(later.dx - start.dx) + abs(later.dy - start.dy) > ScreensaverDrift.amplitude / 4)
    }
}
