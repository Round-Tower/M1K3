//
//  MenuBarLabel.swift
//  M1K3App
//
//  The status-bar glyph, alive: the pixel mark plus a small indicator that
//  reflects what M1K3 is doing — a pulsing accent dot while it thinks, a red dot
//  while recording, a soft glow while speaking, nothing when idle. The DECISION
//  is the unit-tested `AvatarActivity.glyphTreatment(isRecording:)`; this view
//  just renders it. Pulse uses `TimelineView` (menu-bar labels don't reliably run
//  implicit repeating animations); the steady colour is correct even if it doesn't.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.7, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the pulsing dot's timeline is
//  capped at 30 fps on an elapsed clock (was the display's native 120 Hz).
//  Confidence now 0.8 (verify-by-launch).
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the glyph breathes while a brain / voice /
//  recogniser model loads (`GlyphTreatment.breathes`, test-pinned). Confidence 0.8 (verify-by-launch).
//  Review: Kev + claude-opus-4-8, 2026-09-13 — ★ the breathing glyph LIVELOCKED launch.
//  A MenuBarExtra label rasterises into the NSStatusItem button; a per-frame TimelineView
//  re-ran _adjustLength + full menu-bar Auto Layout every frame, monopolising the main thread
//  for the whole model-warm window so the :4242 MCP bind never ran and warm never finished
//  (one process pegged at 20 GB / 100 % CPU, proven by `sample`). Loading cue is now a static
//  dim; motion belongs on the button CALayer, not the label. Confidence 0.85 (verify-by-launch).

import Foundation
import M1K3Avatar
import SwiftUI

struct MenuBarLabel: View {
    let env: AppEnvironment?
    let glyphStyle: MenuBarGlyphStyle

    private var treatment: GlyphTreatment {
        guard let env else { return .calm }
        return env.avatar.state.activity.glyphTreatment(isRecording: env.isRecording, isLoading: isLoading)
    }

    /// Any model warming: the selected brain's weights, M1K3 Voice, or the
    /// WhisperKit recogniser. The three load states the Settings panes already
    /// render — the glyph breathes for the same reason those show a bar.
    private var isLoading: Bool {
        guard let env else { return false }
        return env.modelLoad.isActive || env.voiceLoad.isActive || env.whisperLoad.isActive
    }

    /// The pixel glyph carries no VoiceOver name of its own; speak the same signal
    /// the overlay dot renders. Recording wins over activity here too — the same
    /// precedence `glyphTreatment(isRecording:)` already encodes for the dot.
    private var accessibilityLabel: String {
        guard let env else { return "M1K3" }
        if env.isRecording { return "M1K3 — Recording" }
        return env.avatar.state.activity.accessibilityLabel
    }

    var body: some View {
        let treatment = treatment
        BreathingGlyph(image: glyphStyle.image(), breathes: treatment.breathes)
            .shadow(
                color: treatment.dot == .glow ? .glyphDot(treatment.dotColorName) : .clear,
                radius: treatment.dot == .glow ? 2.5 : 0
            )
            .overlay(alignment: .topTrailing) {
                if treatment.dot == .pulsing || treatment.dot == .recording {
                    // No offset: stay inside the glyph frame so the dot can't be
                    // clipped by the menu bar's tight item bounds.
                    IndicatorDot(color: .glyphDot(treatment.dotColorName), pulses: treatment.pulses)
                }
            }
            .accessibilityLabel(accessibilityLabel)
    }
}

extension Color {
    /// Map a `GlyphTreatment.dotColorName` to a Color. Shared by the menu-bar
    /// label and the popover header so the two stay in lockstep.
    static func glyphDot(_ name: String?) -> Color {
        switch name {
        case "accent": .accentColor
        case "red": .red
        default: .secondary
        }
    }
}

/// The pixel mark, dimmed while a model loads. ★ 2026-09-13: this MUST NOT be a
/// per-frame `TimelineView`. A `MenuBarExtra` label is rasterised into the
/// `NSStatusItem` button image, and every frame re-runs `NSStatusItem
/// _adjustLength` → a full Auto Layout pass on the menu bar (proven by `sample`).
/// `breathes` is true for the whole launch/model-warm window, so a per-frame
/// animation here MONOPOLISES the main thread → the main-actor launch work
/// (incl. the :4242 MCP bind) is starved → warm never finishes → `breathes`
/// stays true: a self-sustaining livelock that pegged one 20 GB / 100 % CPU
/// process and never launched. The loading cue is now a single, static dim
/// (one re-raster on entry, one on exit). Motion, if wanted, belongs on the
/// status button's CALayer opacity (GPU, no re-layout), never on the label body.
private struct BreathingGlyph: View {
    let image: NSImage
    let breathes: Bool

    var body: some View {
        Image(nsImage: image)
            .opacity(breathes ? 0.6 : 1.0)
    }
}

/// A tiny status dot. Pulses via a TimelineView (steady colour is the meaning;
/// the breathe is a best-effort flourish that survives the menu bar's quirks).
private struct IndicatorDot: View {
    let color: Color
    let pulses: Bool
    /// Elapsed-since-mount clock origin (the AudioCaptureBackdrop precision
    /// lesson, applied for consistency — small sin() arguments).
    @State private var start = Date()

    var body: some View {
        Group {
            if pulses {
                // 30 fps cap (2026-09-12 thermal audit): a 4.5 pt dot breathing
                // at 3 rad/s does not need the display's native 120 Hz. Only
                // mounted while thinking/recording — an ACTIVE cost, made 4× smaller.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = context.date.timeIntervalSince(start)
                    Circle()
                        .fill(color)
                        .opacity(0.5 + 0.5 * (0.5 + 0.5 * sin(phase * 3)))
                }
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 4.5, height: 4.5)
    }
}
