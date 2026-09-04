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

import M1K3Chat
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
            // A navigation cancelled by a newer load isn't a real failure.
            let nsError = error as NSError
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
                parent.isLoading = false
                return
            }
            parent.loadError = nsError.localizedDescription
            parent.isLoading = false
        }
    }
}
