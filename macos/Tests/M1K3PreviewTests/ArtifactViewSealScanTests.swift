//
//  ArtifactViewSealScanTests.swift
//  M1K3PreviewTests
//
//  Source-scan pins on the artifact preview's seal (the PageHostScanTests idiom): the WKWebView host
//  is app code with no pure seam, and it now compiles into the iOS shell too. Nothing else pinned
//  ArtifactView.swift. The rule decisions are pinned in ArtifactSandboxPolicyTests; this pins that
//  the host USES them, in order: scripts off, the rule list compiled and added BEFORE any load, a seal
//  failure loading the placeholder and never the content, and no link preview on iOS.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.7 (coarse tripwires on spelling; the
//  behaviour is verify-on-device). Prior: Unknown (new file).

import Foundation
import Testing

struct ArtifactViewSealScanTests {
    private static var source: String {
        get throws {
            // …/macos/Tests/M1K3PreviewTests/<this file>
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let text = try String(
                contentsOf: root.appendingPathComponent("M1K3App/ArtifactView.swift"), encoding: .utf8
            )
            #expect(!text.isEmpty, "scan read an empty file: ArtifactView.swift moved")
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
    }

    private static func index(of needle: String, in text: String) throws -> String.Index {
        try #require(text.range(of: needle)?.lowerBound, "ArtifactView.swift no longer contains: \(needle)")
    }

    @Test("scripts stay off and the data store stays non-persistent")
    func scriptsOff() throws {
        let text = try Self.source
        #expect(text.contains("allowsContentJavaScript = false"))
        #expect(!text.contains("allowsContentJavaScript = true"))
        #expect(text.contains("websiteDataStore = .nonPersistent()"))
        #expect(!text.contains("javaScriptEnabled"))
    }

    @Test("the rule list is compiled and added before ANY load")
    func ruleListBeforeLoad() throws {
        let text = try Self.source
        let compile = try Self.index(of: "compileContentRuleList(", in: text)
        let add = try Self.index(of: "userContentController.add(list)", in: text)
        let firstLoad = try Self.index(of: "loadHTMLString(", in: text)
        #expect(compile < add)
        #expect(add < firstLoad, "a load ahead of the rule list would be an unsealed one")
        #expect(!text.contains(".load(URLRequest"), "the preview loads a string, never a URL")
        #expect(text.contains("ArtifactSandboxPolicy.contentRuleListJSON"))
    }

    @Test("a seal that will not compile loads the placeholder, never the content")
    func failsClosed() throws {
        let text = try Self.source
        let content = try Self.index(of: "loadHTMLString(source", in: text)
        let add = try Self.index(of: "userContentController.add(list)", in: text)
        #expect(add < content)
        #expect(text.contains("loadHTMLString(ArtifactFallback.sealFailureHTML"))
        // The content load sits in the `if let list` arm: the only `loadHTMLString(source` is after
        // the add, and there is exactly one.
        #expect(text.components(separatedBy: "loadHTMLString(source").count == 2)
    }

    @Test("navigation is judged by the tested policy")
    func navigationPolicy() throws {
        let text = try Self.source
        #expect(text.contains("ArtifactSandboxPolicy.allowsNavigation(scheme:"))
        #expect(text.contains("webView.navigationDelegate = navigationGuard"))
    }

    @Test("iOS shows no link preview, which would fetch outside the rule list")
    func noLinkPreview() throws {
        let text = try Self.source
        #expect(text.contains("allowsLinkPreview = false"))
        #expect(!text.contains("allowsLinkPreview = true"))
    }
}
