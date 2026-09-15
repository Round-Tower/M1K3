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
//  Review: Kev + claude-opus-5, 2026-09-15 — the breath is back, where the 09-13 note said it belongs:
//  `StatusItemBreath` animates the NSStatusBarButton's CALayer opacity (a render-server animation, no
//  per-frame main-thread work, no re-raster, no _adjustLength). The label only asks once per transition
//  (`.task(id:)`); the static dim stays as the fallback for Reduce Motion or a button it can't find.
//  Confidence 0.75 (verify-by-launch: sampled main thread during a warm, the glyph captured breathing).

import AppKit
import Foundation
import M1K3Avatar
import os
import QuartzCore
import SwiftUI

struct MenuBarLabel: View {
    let env: AppEnvironment?
    let glyphStyle: MenuBarGlyphStyle
    /// True while the status button's own layer carries the breath, so the
    /// label drops its static dim (the two together would dim twice).
    @State private var breathesOnLayer = false
    /// Read live so a Reduce Motion switch mid-load stops the breath at once,
    /// not at the next loading transition (review fold, 2026-09-15).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        BreathingGlyph(image: glyphStyle.image(), breathes: treatment.breathes && !breathesOnLayer)
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
            // Once per transition, never per frame: the breath itself runs on the
            // status button's layer in the render server (see StatusItemBreath).
            .task(id: [treatment.breathes, reduceMotion]) {
                breathesOnLayer = StatusItemBreath.set(treatment.breathes, reduceMotion: reduceMotion)
            }
    }
}

/// The loading breath on the status-bar glyph, done where motion is cheap: the
/// NSStatusBarButton's CALayer opacity. A Core Animation animation runs in the
/// render server — no main-thread work per frame, no re-raster of the label, no
/// `NSStatusItem _adjustLength`. ★ 2026-09-13: the SwiftUI-label version (a
/// per-frame TimelineView) livelocked launch; this is the shape that note asked for.
@MainActor
enum StatusItemBreath {
    private static let key = "app.m1k3.statusItem.breath"
    private static let log = Logger(subsystem: "app.m1k3", category: "launch")

    /// Start or stop the breath. Returns whether it now runs on the button's
    /// layer — false when stopped, when Reduce Motion is on, or when no status
    /// button can be found, and the label then keeps its static dim.
    @discardableResult
    static func set(_ breathing: Bool, reduceMotion: Bool) -> Bool {
        let layers = statusButtonLayers()
        let animate = breathing && !reduceMotion && !layers.isEmpty
        for layer in layers {
            if animate {
                guard layer.animation(forKey: key) == nil else { continue }
                let breath = CABasicAnimation(keyPath: "opacity")
                breath.fromValue = 1.0
                breath.toValue = 0.35
                breath.duration = 0.9
                breath.autoreverses = true
                breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(breath, forKey: key)
            } else {
                layer.removeAnimation(forKey: key)
            }
        }
        log.notice("status glyph breath \(animate ? "on" : "off", privacy: .public) (buttons: \(layers.count, privacy: .public))")
        return animate
    }

    /// MenuBarExtra keeps its NSStatusItem private, but the item's button lives
    /// in an in-process `NSStatusBarWindow`. Every such window's button, in case
    /// the system hosts one per display.
    private static func statusButtonLayers() -> [CALayer] {
        var layers: [CALayer] = []
        for window in NSApp.windows where window.className == "NSStatusBarWindow" {
            guard let content = window.contentView, let button = firstStatusButton(in: content) else { continue }
            button.wantsLayer = true
            if let layer = button.layer { layers.append(layer) }
        }
        return layers
    }

    private static func firstStatusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = firstStatusButton(in: subview) { return button }
        }
        return nil
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
/// status button's CALayer opacity (GPU, no re-layout), never on the label body —
/// `StatusItemBreath` does that since 2026-09-15; this dim is its fallback.
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
