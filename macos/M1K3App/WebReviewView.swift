//
//  WebReviewView.swift
//  M1K3App
//
//  An in-app web view for reviewing a link without leaving M1K3 — just the page,
//  a thin top loading line, and an error state. The chrome (address, open-in-
//  browser, choose-file) lives in ReviewPanel's single slim bar, so this view
//  carries no toolbar of its own — one row of chrome for the whole panel.
//
//  Privacy: a NON-persistent data store, so a page reviewed here leaves no
//  cookies, cache, or history behind — matching M1K3's "nothing lingers" ethos.
//  The view is keyed by URL (`.id(url)` at the call site), so a new link gets a
//  fresh web view. Verify-by-run — the bridge has no pure logic; the routing brain
//  is the tested M1K3Preview package.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-19, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-09-27 — #269 part 2: a navigation policy. WebKit followed a
//  page's own redirect, script or meta refresh into private space outside the gate, and the panel
//  captured that page into the chat; `WebURLPolicy.refusesNavigation` now judges every main-frame
//  move. A person's click passes. Confidence 0.75 (verify-by-run; a script-synthesised click reads
//  as a click — WebKit gives no user-gesture bit here).
//  Review: same day (2) — found live: WebKit reports the cancel as a failed load ("Frame load
//  interrupted") and that overwrote the note; the coordinator keeps its refusal for it. Confidence 0.8.
//  Review: same day (3), #443 review — the first load is the panel's own and passes (a typed
//  Tailscale name worked before and must still); its start is judged once. A refusal superseded
//  by a newer decision stays silent, and WebKit's policy-cancel failure (102) is ignored, so no
//  note lands on the wrong page. Confidence 0.8.

import M1K3Chat
import M1K3Preview
import os
import SwiftUI
import WebKit

struct WebReviewView: View {
    let url: URL
    /// Fired when a page finishes loading, with the rendered document's title
    /// and text — what the model gets to know about "this page" (BrowserContext).
    /// Read from the live DOM, so JavaScript-rendered sites count too.
    var onPageLoaded: @MainActor (BrowserContext) -> Void = { _ in }

    @State private var webView = WebReviewView.makeWebView()
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        WebViewContainer(
            webView: webView, url: url, isLoading: $isLoading, loadError: $loadError,
            onPageLoaded: onPageLoaded
        )
        // A thin indeterminate hairline while loading — slicker than a spinner
        // button, and it takes no chrome height of its own.
        .overlay(alignment: .top) {
            if isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        .overlay { if let loadError { errorOverlay(loadError) } }
        .animation(.easeOut(duration: 0.2), value: isLoading)
    }

    /// A private, non-persistent WebKit profile: no cookies/cache/history survive.
    private static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: config)
    }

    private func errorOverlay(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t load the page", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") {
                loadError = nil
                webView.reload()
            }
            .buttonStyle(.glassProminent)
        }
        .background(.regularMaterial)
    }
}

/// The WKWebView bridge: installs the supplied web view and loads the URL once
/// (the call site keys the whole view by URL, so a new link rebuilds this and
/// triggers a fresh load). Loading / error state is mirrored back through bindings
/// by the coordinator, which WebKit always calls on the main thread.
private struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    let url: URL
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    let onPageLoaded: @MainActor (BrowserContext) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    /// Intentionally a no-op: the view is keyed by URL at the call site, so a URL
    /// change rebuilds the whole representable (and re-fires makeNSView).
    func updateNSView(_: WKWebView, context _: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: WebViewContainer

        init(_ parent: WebViewContainer) {
            self.parent = parent
        }

        private static let securityLog = Logger(subsystem: "app.m1k3", category: "security")

        /// Whether this panel's first load started on a private address, judged once as it
        /// opens (`WebURLPolicy.startsPrivate`). nil until that first load arrives.
        private var start: Task<Bool, Never>?
        /// Bumped per decision; a refusal that finishes after a newer decision began says
        /// nothing, so it can't paint its note over the page that won (#443 review).
        private var latestDecision = 0

        /// Every main-frame move after the first, server redirects included, is judged
        /// (#269): a page that started public can't carry the panel into private space by
        /// itself. The first load is the panel's own — already gated where an agent opened
        /// it, deliberately ungated where the person typed it (#443 review). Subframes aren't
        /// captured, so they're left to WebKit.
        func webView(
            _: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.targetFrame?.isMainFrame ?? true,
                  let target = navigationAction.request.url,
                  target.scheme == "http" || target.scheme == "https"
            else { return .allow }
            guard let start else {
                let url = parent.url
                start = Task { await WebURLPolicy.startsPrivate(url, resolver: SystemHostResolver()) }
                return .allow
            }
            latestDecision += 1
            let decision = latestDecision
            let refused = await WebURLPolicy.refusesNavigation(
                startedPrivate: start.value, to: target,
                userInitiated: navigationAction.navigationType == .linkActivated,
                resolver: SystemHostResolver()
            )
            guard refused else { return .allow }
            Self.securityLog.notice("review panel: a page-driven move into private space was refused")
            if decision == latestDecision {
                parent.isLoading = false
                parent.loadError = String(localized: "This page tried to send the panel to a local or private-network address. M1K3 won’t open those on a page’s say-so.")
            }
            return .cancel
        }

        func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            parent.loadError = nil
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            parent.isLoading = false
            capturePage(webView)
        }

        /// The rendered document, capped in the page (4k chars) before it crosses
        /// into Swift; BrowserContext caps again for the prompt. Errors (a page
        /// that blocks script evaluation, a torn-down view) just mean no context.
        private func capturePage(_ webView: WKWebView) {
            let script = "[document.title || '', ((document.body && document.body.innerText) || '').slice(0, 4000)]"
            let pageURL = webView.url ?? parent.url
            webView.evaluateJavaScript(script) { [parent] result, _ in
                guard let pair = result as? [String], pair.count == 2 else { return }
                MainActor.assumeIsolated {
                    parent.onPageLoaded(BrowserContext(url: pageURL, title: pair[0], text: pair[1]))
                }
            }
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            fail(error)
        }

        /// target="_blank" / window.open() — WebKit only opens a new window if a
        /// UIDelegate handles it. Load the request in-place instead of dropping it.
        func webView(
            _ webView: WKWebView,
            createWebViewWith _: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures _: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, navigationAction.request.url != nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private func fail(_ error: Error) {
            let nsError = error as NSError
            // WebKit's "Frame load interrupted": a navigation a policy cancelled — ours, whose
            // note is already up, or one a newer decision superseded. Never the page's failure.
            if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
            // A navigation cancelled by a newer load isn't a real failure.
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
                parent.isLoading = false
                return
            }
            parent.loadError = nsError.localizedDescription
            parent.isLoading = false
        }
    }
}
