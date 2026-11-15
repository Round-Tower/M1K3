//
//  VoicePageWebView.swift
//  M1K3iOS
//
//  The phone's host for the page voice mode opens beside the avatar (#839): a WKWebView built from
//  `PrivateWebConfiguration.make()` (a NON-persistent store: no cookies, cache or history) whose every
//  main-frame move goes through `WebNavigationGuard`, i.e. `WebURLPolicy.refusesNavigation` (#269),
//  the same gate the Mac's panel applies. NEVER SFSafariViewController: it shares Safari's cookies,
//  which breaks "nothing lingers". IOSPageHostScanTests pins all three.
//
//  `VoicePageControl` is the handle the spoken "scroll down" / "go back" commands drive.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.6 (compile-checked; the policy and store
//  are pinned in M1K3PreviewTests; the look and the touch behaviour are verify-on-device). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-15 — #839 review: a refused or failed page shows a short note instead of a
//  blank card (policy cancels stay quiet); `canGoBack`; the guard is the strict one (no trusted clicks, http /
//  https / about only). Confidence 0.6.

import M1K3Preview
import SwiftUI
import WebKit

@MainActor
final class VoicePageControl {
    private weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    /// One page-ish step (80% of the viewport). `smooth` is false under Reduce Motion.
    func scroll(_ command: VoicePageCommand, smooth: Bool) {
        let direction: String
        switch command {
        case .scrollDown: direction = "1"
        case .scrollUp: direction = "-1"
        default: return
        }
        let behavior = smooth ? "smooth" : "auto"
        let script = "window.scrollBy({top: window.innerHeight * 0.8 * \(direction), behavior: '\(behavior)'})"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    var canGoBack: Bool {
        webView?.canGoBack ?? false
    }

    @discardableResult
    func goBack() -> Bool {
        guard let webView, webView.canGoBack else { return false }
        webView.goBack()
        return true
    }
}

struct VoicePageWebView: UIViewRepresentable {
    let url: URL
    let control: VoicePageControl
    /// A short line when the page is refused or fails to load; nil when a load starts fine.
    let onFailure: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: PrivateWebConfiguration.make())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        control.attach(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    /// The call site keys the view by URL, so a new page rebuilds it.
    func updateUIView(_: WKWebView, context _: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let navigationGuard: WebNavigationGuard
        private let onFailure: (String?) -> Void

        init(url: URL, onFailure: @escaping (String?) -> Void) {
            navigationGuard = WebNavigationGuard(initialURL: url)
            self.onFailure = onFailure
        }

        func webView(
            _: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let target = navigationAction.request.url else { return .allow }
            let allowed = await navigationGuard.allows(
                target,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                userInitiated: navigationAction.navigationType == .linkActivated
            )
            if !allowed {
                onFailure(String(localized: "M1K3 won't open that link from a page."))
            }
            return allowed ? .allow : .cancel
        }

        func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            onFailure(nil)
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            fail(error)
        }

        private func fail(_ error: Error) {
            let nsError = error as NSError
            // WebKit's "Frame load interrupted" (102) is a policy cancel: ours, whose note is already up.
            if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            onFailure(String(localized: "Couldn't load the page."))
        }

        /// target="_blank" / window.open(): load in place (it goes back through the guard).
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
    }
}

/// The glass card the phone shows the page in, with Close.
struct VoicePageCard: View {
    let url: URL
    let control: VoicePageControl
    let onClose: () -> Void

    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.readableSecondary)
                    .accessibilityHidden(true)
                Text(url.host ?? url.absoluteString)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.large)
                }
                .accessibilityLabel("Close page")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().opacity(0.4)
            VoicePageWebView(url: url, control: control) { failure = $0 }
                .id(url)
                .overlay {
                    if let failure {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .imageScale(.large)
                                .accessibilityHidden(true)
                            Text(failure)
                                .font(.callout)
                                .multilineTextAlignment(.center)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial)
                        .accessibilityElement(children: .combine)
                    }
                }
        }
        .m1k3Glass(cornerRadius: 22)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source page")
    }
}
