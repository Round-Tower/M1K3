//
//  DeferredPanelMount.swift
//  M1K3
//
//  The #79 defense — finally stack-diagnosed (crash 2026-08-06-213458.ips,
//  100% repro: open the inspector on an HTML/preview target):
//
//    AppKit constraint pass → NSHostingView._willUpdateConstraintsForSubtree
//    → SwiftUI SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)
//    → AppKitPlatformViewHost.enqueueLayoutInvalidation → Update.dispatchActions
//    runs it SYNCHRONOUSLY inside the same pass → setNeedsUpdateConstraints →
//    -[NSWindow _postWindowNeedsUpdateConstraints] throws (illegal mid-flush)
//    → uncaught → SIGABRT.
//
//  A hosted AppKit view (WKWebView / QLPreviewView) whose size constraints
//  change while the inspector's split-view child is mid-constraint-update
//  re-enters AppKit layout. The defense: mount the heavy content ONE
//  transaction AFTER the panel appears, so the platform view's first size
//  negotiation happens in a clean pass, never inside the inspector's
//  open/animation flush. Costs one blank frame; beats a process abort.
//
//  Framework race, macOS 26.4 (25E246) — re-test on future SDKs; if Apple
//  fixes the re-entrancy this wrapper degrades to a no-op frame delay.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.75 (diagnosis is
//  read straight off the lastExceptionBacktrace; the fix is the standard
//  defer-out-of-pass shape but the race is timing-dependent — ⌘R the repro:
//  open the panel on an HTML artifact, resize, toggle repeatedly).
//  Prior: none (new file).
//

import SwiftUI

/// Defers its content by one SwiftUI transaction so hosted AppKit views
/// (WKWebView, QLPreviewView) never take their first layout inside the
/// inspector's constraint pass.
struct DeferredPanelMount<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var mounted = false

    var body: some View {
        ZStack {
            if mounted {
                content()
            } else {
                Color.clear
            }
        }
        .task {
            // Task runs after install; the state flip lands in a fresh
            // transaction, outside the pass that mounted this view.
            await Task.yield()
            mounted = true
        }
    }
}
