//
//  ArtifactSandboxPolicy.swift
//  M1K3Preview
//
//  The hermetic seal for the artifact preview. ArtifactView renders UNTRUSTED,
//  model-generated HTML in a live WKWebView — the opposite threat model from
//  WebReviewView (which renders trusted, user-chosen pages). Three layers keep
//  generated code from phoning home, and all three are decided here so a typo
//  fails a test instead of silently un-sealing the preview:
//
//   1. JavaScript is disabled by the caller (no JS ⇒ no fetch/WebSocket/script egress).
//   2. `contentRuleListJSON` blocks every sub-resource load, re-allowing only the
//      inert about:/data: schemes — and the WebView must fail CLOSED if it won't compile.
//   3. `contentSecurityPolicy` / `cspMetaTag` seal the egress vectors a content
//      rule list cannot reach (WebSocket/fetch/XHR/EventSource via connect-src 'none').
//
//  `allowsNavigation(scheme:)` is the navigation-delegate allowlist (top-level loads).
//
//  Signed: claude-opus-4-8, 2026-06-20, Confidence 0.88, Prior: Unknown
//  (Extracted from inline literals in ArtifactView.swift after a security review
//   flagged the seal as untested + fail-open; the rule-list string itself is the
//   PR author's, now pinned by ArtifactSandboxPolicyTests.)
//  Review: Kev + claude-opus-5-5, 2026-11-23 (challenger on sealed interactive pages) — a top-level `data:`
//  navigation is refused (a fresh document with no CSP), and the CSP now leads every document instead of being
//  spliced into a `<head>` the page could hide or precede (ArtifactFormatter.injectCSPMeta). Confidence 0.85.

import Foundation

public enum ArtifactSandboxPolicy {
    /// The store identifier for the compiled block list.
    public static let contentRuleListIdentifier = "m1k3-artifact-block"

    /// Block ALL sub-resource loads (images, scripts, stylesheets, fetch/XHR),
    /// then re-allow only the inert in-page schemes. A WKContentRuleList url-filter
    /// is a regex; `^about:` / `^data:` are anchored so nothing else slips the block.
    public static let contentRuleListJSON = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
    """

    /// Schemes a top-level navigation may use inside the hermetic preview. A nil
    /// scheme (relative URL / in-page anchor) maps to the empty scheme and is
    /// allowed; everything network- or file-bound is cancelled.
    /// Not `data:`: a clicked data: link is a fresh document that carries no CSP of ours (challenger, 2026-11-23).
    public static func allowsNavigation(scheme: String?) -> Bool {
        ["about", ""].contains((scheme ?? "").lowercased())
    }

    /// CSP that closes the WebSocket/fetch/XHR/EventSource egress a content rule
    /// list does not cover. `connect-src 'none'` is the load-bearing directive;
    /// data:-URI images and inline styles are permitted so static previews still render.
    public static let contentSecurityPolicy =
        "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; connect-src 'none'"

    /// The CSP as a `<meta>` element to inject at the top of a formatted document's `<head>`.
    public static var cspMetaTag: String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"
    }
}
