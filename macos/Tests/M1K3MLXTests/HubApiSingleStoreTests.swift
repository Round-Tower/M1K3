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
//  Review: same day (#499 review follow-up) — scans M1K3App/ and M1K3iOSApp/ too; a call counts as commented
//  out only when its line starts with `//`.

import Foundation
import Testing

struct HubApiSingleStoreTests {
    @Test("every HubApi(...) M1K3 constructs passes cache: nil")
    func everyHubApiIsSingleStore() throws {
        // Every tree that can construct a HubApi: the package, the Mac app, the iOS/visionOS shell.
        let macos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var swiftFiles: [URL] = []
        for root in ["Sources", "M1K3App", "M1K3iOSApp"] {
            let dir = macos.appendingPathComponent(root)
            guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                swiftFiles.append(url)
            }
        }
        var sites = 0
        for url in swiftFiles {
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
                // Commented out only when the LINE starts with `//` — a `//` earlier on the line (a
                // URL in a string) must not hide a real call (#499 review).
                let newline = rest[..<open.lowerBound].lastIndex(of: "\n")
                let lineStart = newline.map { rest.index(after: $0) } ?? rest.startIndex
                let isComment = rest[lineStart ..< open.lowerBound]
                    .trimmingCharacters(in: .whitespaces).hasPrefix("//")
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
