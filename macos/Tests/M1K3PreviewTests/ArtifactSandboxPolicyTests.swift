//
//  ArtifactSandboxPolicyTests.swift
//  M1K3PreviewTests
//
//  Pins the two security decisions that keep the artifact preview hermetic:
//  the WKContentRuleList JSON (sub-resource block) and the navigation scheme
//  allowlist. Both render UNTRUSTED model-generated HTML, so a silent typo in
//  either must fail a test, not ship.
//

import Foundation
@testable import M1K3Preview
import Testing

struct ArtifactSandboxPolicyTests {
    // MARK: - Content rule list JSON

    @Test("the content rule list is valid JSON")
    func ruleListIsValidJSON() throws {
        let data = Data(ArtifactSandboxPolicy.contentRuleListJSON.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data)
        let array = try #require(parsed as? [[String: Any]])
        #expect(array.count >= 1)
    }

    @Test("the rule list blocks ALL urls via a catch-all .* trigger")
    func ruleListHasCatchAllBlock() throws {
        let data = Data(ArtifactSandboxPolicy.contentRuleListJSON.utf8)
        let array = try #require(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let blockRule = array.first { rule in
            let trigger = rule["trigger"] as? [String: Any]
            let action = rule["action"] as? [String: Any]
            return (trigger?["url-filter"] as? String) == ".*"
                && (action?["type"] as? String) == "block"
        }
        #expect(blockRule != nil, "a typo in the catch-all block silently disables the seal")
    }

    @Test("the rule list re-allows only about: and data: via ignore-previous-rules")
    func ruleListAllowsOnlyInertSchemes() throws {
        let data = Data(ArtifactSandboxPolicy.contentRuleListJSON.utf8)
        let array = try #require(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let ignored = array.compactMap { rule -> String? in
            let trigger = rule["trigger"] as? [String: Any]
            let action = rule["action"] as? [String: Any]
            guard (action?["type"] as? String) == "ignore-previous-rules" else { return nil }
            return trigger?["url-filter"] as? String
        }
        #expect(Set(ignored) == ["^about:", "^data:"])
    }

    // MARK: - Navigation scheme allowlist

    @Test("inert/in-page navigation schemes are allowed")
    func allowsInertSchemes() {
        #expect(ArtifactSandboxPolicy.allowsNavigation(scheme: "about"))
        #expect(ArtifactSandboxPolicy.allowsNavigation(scheme: ""))
        // A clicked data: link is a fresh document with no CSP of ours (challenger, 2026-11-23): refused.
        #expect(!ArtifactSandboxPolicy.allowsNavigation(scheme: "data"))
        #expect(!ArtifactSandboxPolicy.allowsNavigation(scheme: "DATA"))
        // A nil scheme (relative / in-page anchor) is treated as the empty scheme → allowed.
        #expect(ArtifactSandboxPolicy.allowsNavigation(scheme: nil))
    }

    @Test("network and local-file schemes are cancelled")
    func cancelsNetworkSchemes() {
        for scheme in ["http", "https", "file", "ftp", "javascript", "ws", "wss"] {
            #expect(
                !ArtifactSandboxPolicy.allowsNavigation(scheme: scheme),
                "\(scheme) must not be navigable from the hermetic preview"
            )
        }
    }

    // MARK: - Content Security Policy (defense in depth)

    @Test("the CSP seals the egress vectors the rule list misses (connect-src none)")
    func cspBlocksConnectAndDefaultSrc() {
        let csp = ArtifactSandboxPolicy.contentSecurityPolicy
        // connect-src 'none' is what stops WebSocket/fetch/XHR/EventSource — the
        // documented WKContentRuleList blind spot.
        #expect(csp.contains("connect-src 'none'"))
        #expect(csp.contains("default-src 'none'"))
    }

    @Test("the CSP meta tag is a well-formed http-equiv element")
    func cspMetaTagIsWellFormed() {
        let tag = ArtifactSandboxPolicy.cspMetaTag
        #expect(tag.contains("http-equiv=\"Content-Security-Policy\""))
        #expect(tag.contains(ArtifactSandboxPolicy.contentSecurityPolicy))
    }
}

/// Pages that try to keep our CSP from applying: the policy must lead every document, after a leading doctype only,
/// whatever the page holds (challenger on 2026-11-23: no <head>, a <head> in a comment, a script before the head, and
/// the policy's own text in the body each skipped or delayed the old splice).
struct ArtifactCSPLeadsTests {
    static let hostile = [
        "<!doctype html><html><body><p>x</p></body></html>",
        "<!DOCTYPE html>\n<html><!-- <head> --><body><script>steal()</script></body></html>",
        "<!DOCTYPE html>\n<html><script>steal()</script><head></head><body></body></html>",
        "<p>\(ArtifactSandboxPolicy.contentSecurityPolicy)</p>",
        "<!DOCTYPE html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src *\"></head></html>",
        "<script>steal()</script><h1>Hi</h1>",
        "   <!doctype html>\n<html><head></head><body>x</body></html>",
    ]

    /// The document with its leading doctype (and any whitespace) removed.
    static func afterDoctype(_ html: String) -> Substring {
        var rest = Substring(html).drop { $0.isWhitespace }
        if rest.lowercased().hasPrefix("<!doctype"), let close = rest.firstIndex(of: ">") {
            rest = rest[rest.index(after: close)...].drop { $0.isWhitespace }
        }
        return rest
    }

    @Test("our CSP is the first element of every injected document, whatever the page holds")
    func cspLeadsInjected() {
        for page in Self.hostile {
            let out = ArtifactFormatter.injectCSPMeta(page)
            #expect(Self.afterDoctype(out).hasPrefix(ArtifactSandboxPolicy.cspMetaTag), "not first in: \(page)")
        }
    }

    @Test("our CSP leads every formatted page too, and injecting twice adds it once")
    func cspLeadsFormattedAndIdempotent() {
        for page in Self.hostile {
            let out = ArtifactFormatter.formatHTML(page)
            #expect(Self.afterDoctype(out).hasPrefix(ArtifactSandboxPolicy.cspMetaTag), "not first in: \(page)")
            let twice = ArtifactFormatter.injectCSPMeta(ArtifactFormatter.injectCSPMeta(page))
            #expect(twice.components(separatedBy: ArtifactSandboxPolicy.cspMetaTag).count == 2, "twice in: \(page)")
        }
    }
}

/// DNS prefetch is the one egress no CSP directive and no content rule list governs: `<link rel=dns-prefetch>` (or
/// WebKit's own prefetch of a link's host) resolves a name the page chose, which could carry what's on the page. A
/// loopback canary (2026-11-23) showed the rule list stops every fetch channel, but a bare lookup can't be seen
/// without root; `x-dns-prefetch-control: off`, honoured by WebKit, closes it at the source.
struct ArtifactDNSPrefetchOffTests {
    @Test("the seal turns DNS prefetch off, right after the CSP, in every injected document")
    func injectedDocumentsTurnPrefetchOff() {
        for page in ArtifactCSPLeadsTests.hostile {
            let out = ArtifactFormatter.injectCSPMeta(page)
            #expect(ArtifactCSPLeadsTests.afterDoctype(out).hasPrefix(ArtifactSandboxPolicy.sealHead), "not first in: \(page)")
        }
    }

    @Test("formatted html and markdown previews both lead with the full seal, once")
    func formattedPreviewsLeadWithTheSeal() {
        let html = ArtifactFormatter.formatHTML("<p>x</p><link rel=\"dns-prefetch\" href=\"//leak.example\">")
        let markdown = ArtifactFormatter.formatMarkdown("# Hi")
        for out in [html, markdown] {
            #expect(ArtifactCSPLeadsTests.afterDoctype(out).hasPrefix(ArtifactSandboxPolicy.sealHead))
            #expect(out.components(separatedBy: ArtifactSandboxPolicy.dnsPrefetchOffMetaTag).count == 2)
        }
    }

    @Test("a page can't turn prefetch back on: its own prefetch-control metas and its dns-prefetch / preconnect links go")
    func pageCannotReEnablePrefetch() {
        let pages = [
            "<meta http-equiv=\"x-dns-prefetch-control\" content=\"on\"><link rel=\"dns-prefetch\" href=\"//leak.example\">",
            "<META HTTP-EQUIV='X-DNS-Prefetch-Control' CONTENT='on'><p>x</p>",
            "<meta content=\"on\" http-equiv=x-dns-prefetch-control><a href=\"https://leak.example\">a</a>",
            "<link href=\"https://leak.example\" rel=\"preconnect\"><LINK REL=DNS-PREFETCH HREF=//b.example>",
            "<link rel=\"stylesheet preconnect\" href=\"https://leak.example\">",
        ]
        for page in pages {
            for out in [ArtifactFormatter.injectCSPMeta(page), ArtifactFormatter.formatHTML(page)] {
                let lower = out.lowercased()
                #expect(lower.components(separatedBy: "x-dns-prefetch-control").count == 2, "only ours survives: \(page)")
                #expect(!lower.contains("content=\"on\"") && !lower.contains("content='on'"), "\(page)")
                #expect(!lower.contains("leak.example\" rel") && !lower.contains("dns-prefetch href"), "\(page)")
                #expect(!lower.contains("rel=\"preconnect") && !lower.contains("stylesheet preconnect"), "\(page)")
            }
        }
        // Ordinary content survives: a page's links and other metas are not touched.
        let kept = ArtifactFormatter.injectCSPMeta("<meta name=\"author\" content=\"Kev\"><a href=\"#top\">top</a>")
        #expect(kept.contains("<meta name=\"author\" content=\"Kev\">") && kept.contains("<a href=\"#top\">top</a>"))
    }

    @Test("the prefetch switch is the exact http-equiv WebKit reads")
    func prefetchMetaIsWellFormed() {
        #expect(ArtifactSandboxPolicy.dnsPrefetchOffMetaTag == "<meta http-equiv=\"x-dns-prefetch-control\" content=\"off\">")
        #expect(ArtifactSandboxPolicy.sealHead.hasPrefix(ArtifactSandboxPolicy.cspMetaTag))
    }
}
