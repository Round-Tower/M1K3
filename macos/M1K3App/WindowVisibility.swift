//
//  WindowVisibility.swift
//  M1K3App
//
//  "Can anyone see this window?" as a SwiftUI environment value, fed by an
//  AppKit probe. The 2026-09-12 thermal audit found M1K3 idling at ~33-49% CPU
//  with the fan on while the main window showed nothing animated: a RealityView
//  keeps the process-global RealityKit engine (DisplayLinkClock → ARView render
//  callback → Metal commit) running at display rate for as long as it is
//  MOUNTED — including inside an ordered-out, alpha-0 window. Two such hosts
//  existed: the notch HUD's 72 px Fox (window built on first show, never torn
//  down) and the menu-bar popover's full-bleed Fox (the MenuBarExtra window is
//  kept alive, hidden, after it closes). Neither was on screen.
//
//  The fix is a visibility signal every avatar surface can unmount on. This is
//  the one mechanism: attach `.trackWindowVisibility()` at a window's root and
//  `AvatarSurface` (via `AvatarPresence`, M1K3Avatar, test-pinned) drops its
//  RealityView the moment the window is ordered out, minimised, or fully
//  occluded, and mounts it again when it comes back. Surfaces in windows that
//  don't attach the modifier see the default `true` — today's behaviour, never
//  worse.
//
//  Occlusion is the signal (not `isVisible`, not `scenePhase`): NSWindow's
//  `occlusionState` drops `.visible` for ordered-out, miniaturised AND fully
//  covered windows alike, posts `didChangeOcclusionStateNotification` on every
//  change, and reads correctly for the MenuBarExtra + NotchHUD windows that
//  SwiftUI's scene phase never describes. Alpha is ignored by occlusion — the
//  HUD orders front at alpha 0 to slide in, and that IS the moment its Fox
//  should mount.
//
//  VERIFY-BY-LAUNCH: an NSView probe in a real window (no unit seam); the
//  pure mount/pause rule it feeds is pinned in AvatarPresenceTests.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.8 (the hidden-
//  host diagnosis is measured — heap counted the live ARViews and sample
//  attributed the main thread; the AppKit probe is verify-by-launch).
//  Prior: Unknown.
//

import AppKit
import SwiftUI

extension EnvironmentValues {
    /// True while the hosting window is at least partially on screen. Defaults
    /// to true so a surface outside a tracked window behaves as before.
    @Entry var windowVisible: Bool = true
}

extension View {
    /// Publish the hosting window's occlusion-derived visibility as
    /// `\.windowVisible` to this subtree. Attach ONCE at a window's root.
    func trackWindowVisibility() -> some View {
        modifier(WindowVisibilityTracker())
    }
}

private struct WindowVisibilityTracker: ViewModifier {
    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .background(WindowVisibilityReader(isVisible: $visible))
            .environment(\.windowVisible, visible)
    }
}

/// Zero-size probe that reports its window's occlusion-derived visibility.
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context _: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { isVisible = $0 }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context _: Context) {
        nsView.onChange = { isVisible = $0 }
    }

    @MainActor
    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observedWindow: NSWindow?
        private var lastReported: Bool?

        override var isOpaque: Bool {
            false
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observe(window)
            report()
        }

        /// Selector-based so the runtime unregisters on dealloc — a block token
        /// would need a `deinit`, which Swift 6 strict concurrency can't let
        /// touch this @MainActor class's state.
        private func observe(_ window: NSWindow?) {
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.didChangeOcclusionStateNotification, object: observedWindow
                )
            }
            observedWindow = window
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }

        @objc private func occlusionChanged() {
            report()
        }

        private func report() {
            let visible = window.map { $0.occlusionState.contains(.visible) } ?? false
            guard visible != lastReported else { return }
            lastReported = visible
            // viewDidMoveToWindow fires inside a layout pass — never mutate
            // SwiftUI state synchronously from there ("modifying state during
            // view update"). One hop to the next runloop turn is enough.
            let onChange = onChange
            DispatchQueue.main.async { onChange?(visible) }
        }
    }
}
