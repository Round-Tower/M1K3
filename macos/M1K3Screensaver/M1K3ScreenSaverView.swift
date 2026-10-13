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
//  Review: Kev + claude-opus-5-5, 2026-10-13 — #578: each display seeds its own rain once the window knows its
//  screen; the face drifts slowly (ScreensaverDrift); the saver stops animating on macOS's
//  com.apple.screensaver.willstop, the Sonoma-era workaround for a host that keeps a dismissed saver running.
//  Confidence 0.75 (the pure parts are pinned; the host behaviour is verify-by-launch).
//

import AppKit
import M1K3ScreensaverCore
import ScreenSaver

public final class M1K3ScreenSaverView: ScreenSaverView {
    private var field: RainField
    private let density: Double
    /// The host's will-stop broadcast (see `init`); removed in `deinit`.
    private nonisolated(unsafe) var willStopObserver: NSObjectProtocol?
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
        density = isPreview ? 1.0 : 1.3
        field = RainField(columns: columns, density: density, seed: 0x4D31_4B33)
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        // Since Sonoma the legacyScreenSaver host often keeps a dismissed saver animating, and
        // instances pile up (#578). macOS broadcasts this just before the saver stops.
        willStopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAnimation() }
        }
    }

    deinit {
        if let willStopObserver {
            DistributedNotificationCenter.default().removeObserver(willStopObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    // MARK: - Animation

    override public func startAnimation() {
        super.startAnimation()
        // Each display its own rain (#578): the window knows its screen now, not at init.
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let display = (window?.screen?.deviceDescription[key] as? NSNumber)?.uint32Value {
            field = RainField(columns: field.columns, density: density, seed: RainField.seed(forDisplay: display))
        }
    }

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
        drawFace()
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

    /// M1K3's face — the hero. A 13×11 pixel matrix (matching the app's
    /// FaceGrid): a faint CRT backing for every cell, with the eyes + resting
    /// smile lit bright and glowing. Sits a touch above centre; the mark + copy
    /// go below.
    private func drawFace() {
        let faceH = min(bounds.height * 0.40, bounds.width * 0.40
            * CGFloat(PixelFace.rows) / CGFloat(PixelFace.cols))
        let cell = faceH / CGFloat(PixelFace.rows)
        let faceW = cell * CGFloat(PixelFace.cols)
        // A slow wander inside a small box (#578): kinder to the panel than a fixed face.
        let drift = ScreensaverDrift.offset(at: phase)
        let side = min(bounds.width, bounds.height)
        let ox = bounds.midX - faceW / 2 + CGFloat(drift.dx) * side
        let oy = bounds.midY - faceH / 2 + bounds.height * 0.10 + CGFloat(drift.dy) * side // above centre
        let block = cell * 0.72
        let breath = 0.9 + 0.1 * (0.5 + 0.5 * sin(phase * 0.9))

        // Soft phosphor bloom behind the face.
        phosphor.withAlphaComponent(0.05).setFill()
        NSBezierPath(ovalIn: NSRect(x: ox - faceW * 0.15, y: oy - faceH * 0.1,
                                    width: faceW * 1.3, height: faceH * 1.2)).fill()

        let lit = PixelFace.litCells(at: phase)
        for row in 0 ..< PixelFace.rows {
            for col in 0 ..< PixelFace.cols {
                let cx = ox + (CGFloat(col) + 0.5) * cell
                // AppKit origin is bottom-left; the grid is top-down.
                let cy = oy + (CGFloat(PixelFace.rows - 1 - row) + 0.5) * cell
                let r = NSRect(x: cx - block / 2, y: cy - block / 2, width: block, height: block)
                let path = NSBezierPath(roundedRect: r, xRadius: block * 0.28, yRadius: block * 0.28)
                if lit.contains(FaceCell(col: col, row: row)) {
                    phosphor.withAlphaComponent(0.35).setFill() // glow halo
                    NSBezierPath(roundedRect: r.insetBy(dx: -block * 0.25, dy: -block * 0.25),
                                 xRadius: block * 0.4, yRadius: block * 0.4).fill()
                    markColor.withAlphaComponent(CGFloat(breath)).setFill()
                    path.fill()
                } else {
                    markColor.withAlphaComponent(0.05).setFill() // faint CRT backing
                    path.fill()
                }
            }
        }
    }

    /// The M mark, at a given centre + height — used small as a resting
    /// signature beneath the face.
    private func drawMark(centerX: CGFloat, centerY: CGFloat, height: CGFloat, alpha: CGFloat) {
        let markH = height
        let markW = markH * PixelMark.aspectRatio
        let ox = centerX - markW / 2
        let oy = centerY - markH / 2
        markColor.withAlphaComponent(alpha).setFill()
        for cell in PixelMark.cells(gap: 0.12) {
            let x = ox + CGFloat(cell.x) * markW
            let h = CGFloat(cell.height) * markH
            let y = oy + (1 - CGFloat(cell.y)) * markH - h
            let w = CGFloat(cell.width) * markW
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                         xRadius: w * 0.14, yRadius: w * 0.14).fill()
        }
    }

    private func drawPresence() {
        let status = PresenceFormatter.statusLine(presence)
        let heartbeat = PresenceFormatter.heartbeatLine(presence)
        let cx = bounds.midX

        // The M mark, small, as a resting signature under the face.
        let markH = max(14, bounds.height * 0.05)
        drawMark(centerX: cx, centerY: bounds.midY - bounds.height * 0.13,
                 height: markH, alpha: 0.9)

        var y = bounds.midY - bounds.height * 0.20

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
