//
//  HubApiSingleStoreTests.swift
//  M1K3MLXTests
//
//  swift-transformers 1.3.x gives HubApi a second, content-addressed store (`HubCache.default`)
//  that downloads pass through before landing in `downloadBase`. M1K3 keeps ONE store — the
//  model directory inside the container — so every HubApi we construct passes `cache: nil`
//  (no doubled multi-GB weights, no new on-disk location). A source scan, so a new call site
//  can't quietly turn the second store back on (#499 review).
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85, Prior: none (new file).

import Foundation
import Testing

struct HubApiSingleStoreTests {
    @Test("every HubApi(...) M1K3 constructs passes cache: nil")
    func everyHubApiIsSingleStore() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var sites = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            var rest = text[...]
            while let open = rest.range(of: "HubApi(") {
                // The call's argument list, up to its matching paren.
                var depth = 1
                var end = open.upperBound
                while end < rest.endIndex, depth > 0 {
                    if rest[end] == "(" { depth += 1 } else if rest[end] == ")" { depth -= 1 }
                    end = rest.index(after: end)
                }
                let lineStart = rest[..<open.lowerBound].lastIndex(of: "\n") ?? rest.startIndex
                let isComment = rest[lineStart ..< open.lowerBound].contains("//")
                if !isComment {
                    sites += 1
                    #expect(rest[open.lowerBound ..< end].contains("cache: nil"),
                            "\(url.lastPathComponent): \(rest[open.lowerBound ..< end])")
                }
                rest = rest[end...]
            }
        }
        #expect(sites >= 3)
    }
}
