//
//  AudioCaptureBackdrop.swift
//  M1K3App
//
//  Two slow, blurred gradient orbs that drift behind the content while M1K3 is
//  capturing audio — recording a call or taking dictation. An ambient "I'm
//  listening" cue over the Liquid Glass, not a literal level meter. Driven by a
//  TimelineView so the motion is continuous and state-free; honours Reduce Motion
//  by rendering the orbs static.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-08, Confidence 0.75, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the timeline is capped at 30 fps
//  (was the display's native 120 Hz). Confidence now 0.8 (verify-by-launch).

import SwiftUI

struct AudioCaptureBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Captured once so the animation phase starts near zero (see body).
    @State private var start = Date()

    var body: some View {
        if reduceMotion {
            orbs(phase: 0)
        } else {
            // 30 fps cap (2026-09-12 thermal audit): `.animation` alone runs at
            // the display's native rate — 120 Hz on ProMotion — for two orbs
            // under a 56 pt blur the eye can't resolve past ~30. Only mounted
            // while capturing, so this is an ACTIVE cost, but 4× less of one.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                // Elapsed-since-start, NOT timeIntervalSinceReferenceDate (~8e8):
                // a Double can't resolve the ~0.006 rad/frame delta at that
                // magnitude, so cos/sin returned a near-constant and the orbs sat
                // frozen. Normalising to ~0 restores full precision → real motion.
                orbs(phase: timeline.date.timeIntervalSince(start))
            }
        }
    }

    private func orbs(phase elapsed: Double) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let span = min(width, height)
            ZStack {
                orb(color: .accentColor, diameter: span * 1.0, pulse: sin(elapsed * 0.8))
                    .position(
                        x: width * (0.34 + 0.20 * cos(elapsed * 0.55)),
                        y: height * (0.40 + 0.22 * sin(elapsed * 0.55))
                    )
                orb(color: .purple, diameter: span * 0.9, pulse: sin(elapsed * 0.65 + 1))
                    .position(
                        x: width * (0.66 + 0.18 * cos(elapsed * 0.42 + 2)),
                        y: height * (0.58 + 0.20 * sin(elapsed * 0.42 + 2))
                    )
            }
            .blur(radius: 56)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func orb(color: Color, diameter: Double, pulse: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.5), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .scaleEffect(1.0 + 0.10 * pulse) // gentle breathing
    }
}
