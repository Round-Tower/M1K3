//
//  WebReviewControl.swift
//  M1K3App
//
//  A small handle onto the WKWebView a WebReviewView owns, so voice mode's spoken "scroll down",
//  "scroll up" and "go back" (VoicePageGrammar, #839) can drive the page without a second browser.
//  The view registers its web view when it mounts; the handle holds it weakly, so a closed page
//  leaves nothing behind. Verify-by-launch: it is WebKit plumbing with no pure logic.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.7. Prior: none (new file).

import M1K3Preview
import WebKit

@MainActor
final class WebReviewControl {
    private weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func detach() {
        webView = nil
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

    /// Back one page in the web view's own history; false when there is none.
    @discardableResult
    func goBack() -> Bool {
        guard let webView, webView.canGoBack else { return false }
        webView.goBack()
        return true
    }
}
