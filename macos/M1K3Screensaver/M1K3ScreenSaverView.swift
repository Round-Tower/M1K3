//
//  M1K3ScreenSaverView.swift
//  M1K3Screensaver (.saver bundle)
//
//  "What M1K3 got up to while you were away." A screensaver, chosen over an
//  always-on desktop wallpaper (challenger pass, 2026-08-20): it runs only when
//  the Mac is idle — so battery/thermal don't matter, the recording context is
//  cinematic, macOS owns the lifecycle, and it rarely lands in a work
//  screenshot, which dissolves the wallpaper's privacy double-bind.
//
//  v1 is the self-contained visual: black gradient + the ambient pixel-rain +
//  the M brand mark, pulsing. The live layer (poll the loopback MCP for
//  status + read heartbeat.sqlite) is a named follow-up — it fills the
//  `presence` snapshot the drawing already reads, and is gated on verifying
//  what the legacyScreenSaver sandbox permits.
//
//  Drawing is AppKit (NSBezierPath/NSGradient) — a screensaver runs in a
//  sandboxed, RealityKit-hostile process, so NO SwiftUI/RealityKit here. The
//  simulation + geometry + copy are the pure, TDD'd M1K3ScreensaverCore.
//
//  Signed: Kev + claude-opus-4-8, 2026-08-20, Confidence 0.8 (the pure core is
//  TDD'd; the .saver render + install are verify-by-launch in System Settings —
//  a screensaver can't be driven headlessly). Prior: the M mark (PR #142).
//

import AppKit
import M1K3ScreensaverCore
import ScreenSaver

public final class M1K3ScreenSaverView: ScreenSaverView {
    private var field: RainField
    /// Live presence — v1 leaves it resting; the follow-up probe updates it.
    private var presence: PresenceSnapshot = .resting
    private var phase: Double = 0

    // Brand palette (matches the app icon's ground + the phosphor accent).
    private let inkTop = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.102, alpha: 1)
    private let inkBottom = NSColor(srgbRed: 0.024, green: 0.024, blue: 0.031, alpha: 1)
    private let markColor = NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1)
    private let phosphor = NSColor(srgbRed: 0.373, green: 0.816, blue: 0.659, alpha: 1)

    override public init?(frame: NSRect, isPreview: Bool) {
        // Fewer lanes in the tiny System-Settings preview so it doesn't look dense.
        let columns = isPreview ? 18 : 48
        field = RainField(columns: columns, density: isPreview ? 1.0 : 1.3, seed: 0x4D31_4B33)
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    // MARK: - Animation

    override public func animateOneFrame() {
        super.animateOneFrame()
        field.advance(by: animationTimeInterval)
        phase += animationTimeInterval
        setNeedsDisplay(bounds)
    }

    // MARK: - Draw

    override public func draw(_: NSRect) {
        drawBackground()
        drawRain()
        drawMark()
        drawPresence()
    }

    private func drawBackground() {
        NSGradient(colors: [inkTop, inkBottom])?
            .draw(in: bounds, angle: -90)
    }

    private func drawRain() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let laneW = bounds.width / CGFloat(field.columns)
        let block = min(laneW * 0.42, bounds.height * 0.012)
        for drop in field.drops {
            let cx = (CGFloat(drop.column) + 0.5) * laneW
            // core `y`: 0 = top, 1 = bottom. AppKit origin is bottom-left.
            let py = (1 - CGFloat(drop.y)) * bounds.height
            let a = CGFloat(drop.brightness) * 0.30
            phosphor.withAlphaComponent(a).setFill()
            let r = NSRect(x: cx - block / 2, y: py - block / 2, width: block, height: block)
            NSBezierPath(roundedRect: r, xRadius: block * 0.25, yRadius: block * 0.25).fill()
        }
    }

    private func drawMark() {
        // Frame the 5×7 M centred, height ~30% of the shorter dimension.
        let markH = min(bounds.height * 0.30, bounds.width * 0.30 / PixelMark.aspectRatio)
        let markW = markH * PixelMark.aspectRatio
        let ox = bounds.midX - markW / 2
        let oy = bounds.midY - markH / 2 + bounds.height * 0.04 // sit slightly above centre; copy below
        let pulse = 0.82 + 0.18 * (0.5 + 0.5 * sin(phase * 1.1))

        // A faint phosphor bloom behind the mark.
        phosphor.withAlphaComponent(0.05 * CGFloat(pulse)).setFill()
        let bloom = NSRect(x: ox - markW * 0.3, y: oy - markH * 0.15,
                           width: markW * 1.6, height: markH * 1.3)
        NSBezierPath(ovalIn: bloom).fill()

        markColor.withAlphaComponent(CGFloat(pulse)).setFill()
        for cell in PixelMark.cells(gap: 0.12) {
            // core cells are top-left origin in unit space; flip Y into AppKit.
            let x = ox + CGFloat(cell.x) * markW
            let h = CGFloat(cell.height) * markH
            let y = oy + (1 - CGFloat(cell.y)) * markH - h
            let w = CGFloat(cell.width) * markW
            let r = NSRect(x: x, y: y, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: w * 0.12, yRadius: w * 0.12).fill()
        }
    }

    private func drawPresence() {
        let status = PresenceFormatter.statusLine(presence)
        let heartbeat = PresenceFormatter.heartbeatLine(presence)
        let cx = bounds.midX
        var y = bounds.midY - bounds.height * 0.14

        draw(text: status, centeredAtX: cx, y: &y,
             size: max(11, bounds.height * 0.022),
             color: markColor.withAlphaComponent(0.72), mono: true, gap: bounds.height * 0.02)

        if let heartbeat {
            draw(text: heartbeat, centeredAtX: cx, y: &y,
                 size: max(10, bounds.height * 0.017),
                 color: markColor.withAlphaComponent(0.42), mono: false,
                 gap: 0, maxWidth: bounds.width * 0.7)
        }
    }

    private func draw(
        text: String, centeredAtX cx: CGFloat, y: inout CGFloat,
        size: CGFloat, color: NSColor, mono: Bool, gap: CGFloat, maxWidth: CGFloat? = nil
    ) {
        let font = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
            : NSFont.systemFont(ofSize: size, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para,
            .kern: mono ? 0.5 : 0,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let bound = maxWidth ?? bounds.width * 0.85
        let box = NSRect(x: cx - bound / 2, y: y - size * 1.4, width: bound, height: size * 1.4)
        str.draw(in: box)
        y -= size * 1.4 + gap
    }
}
