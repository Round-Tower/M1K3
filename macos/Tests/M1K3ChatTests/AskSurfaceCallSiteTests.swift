//
//  AskSurfaceCallSiteTests.swift
//  M1K3ChatTests
//
//  The text-scan guard for the MCP withhold's fail-open edges (#523 second-pass
//  review). Three wiring facts live in the app shells (not SwiftPM targets), so
//  they are read from disk the way SubsystemGuardTests reads Logger sites:
//
//   1. Every `intelligenceAsk(` call site names its `surface:` — the parameter
//      has no default, and this pins that nobody re-adds one by wrapping it.
//      A caller that forgot would silently keep Photos on a new MCP-like path.
//   2. Every store-reading tool `interactiveAgentTools` builds passes
//      `excludedKinds:` — the next knowledge tool joins the withhold or fails here.
//   3. `makeAgentResponder` allocates its ToolSourceCollector per call, so the
//      `.mcp` responder's collector is its own, never shared with the local one.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8 (a text scan, not a
//  compile dependency: it reads the shells' source, so a rename of the builder or
//  the call must update the patterns here). Prior: Unknown
//

import Foundation
import Testing

struct AskSurfaceCallSiteTests {
    private static func packageRoot() throws -> URL {
        var root = URL(filePath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root = root.deletingLastPathComponent()
            try #require(root.path != "/", "no Package.swift above \(#filePath)")
        }
        return root
    }

    /// Every Swift file under the two app shells, as (relative path, text).
    private static func shellSources() throws -> [(path: String, text: String)] {
        let root = try packageRoot()
        var files: [(String, String)] = []
        for shell in ["M1K3App", "M1K3iOSApp"] {
            let dir = root.appending(path: shell)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            while let url = walker.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let relative = String(url.path.dropFirst(root.path.count + 1))
                try files.append((relative, String(contentsOf: url, encoding: .utf8)))
            }
        }
        return files
    }

    /// The argument list of every `marker(` occurrence, balanced to its closing paren.
    private static func callArguments(of marker: String, in text: String) -> [String] {
        var calls: [String] = []
        var search = text.startIndex
        while let range = text.range(of: marker, range: search ..< text.endIndex) {
            var depth = 0
            var index = text.index(before: range.upperBound) // the "("
            var end = text.endIndex
            while index < text.endIndex {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" {
                    depth -= 1
                    if depth == 0 { end = index; break }
                }
                index = text.index(after: index)
            }
            calls.append(String(text[range.upperBound ..< end]))
            search = range.upperBound
        }
        return calls
    }

    @Test("every intelligenceAsk( call site in the shells names its surface")
    func everyAskNamesItsSurface() throws {
        var calls = 0
        var offenders: [String] = []
        for (path, text) in try Self.shellSources() {
            for arguments in Self.callArguments(of: "intelligenceAsk(", in: text) {
                // The declaration's parameter list names the TYPE; a call names a case.
                if arguments.contains("AskSurface") { continue }
                calls += 1
                if !arguments.contains("surface: .") { offenders.append(path) }
            }
        }
        #expect(calls >= 2, "scanned only \(calls) intelligenceAsk call sites — the guard would pass vacuously")
        #expect(offenders.isEmpty, "these intelligenceAsk calls do not say who is asking: \(offenders)")
    }

    @Test("every store-reading tool in interactiveAgentTools passes excludedKinds")
    func everyStoreToolInThePaletteTakesExcludedKinds() throws {
        let root = try Self.packageRoot()
        let text = try String(
            contentsOf: root.appending(path: "M1K3App/AppEnvironment+ChatHistory.swift"), encoding: .utf8
        )
        let builder = try #require(text.range(of: "static func interactiveAgentTools("))
        let body = String(text[builder.upperBound...])
        let stop = body.range(of: "\n    }\n")?.lowerBound ?? body.endIndex
        let palette = String(body[..<stop])
        var storeTools = 0
        var offenders: [String] = []
        var search = palette.startIndex
        while let range = palette.range(of: "Tool(store: store", range: search ..< palette.endIndex) {
            storeTools += 1
            let lineStart = palette[..<range.lowerBound].lastIndex(of: "\n").map { palette.index(after: $0) }
                ?? palette.startIndex
            let lineEnd = palette[range.lowerBound...].firstIndex(of: "\n") ?? palette.endIndex
            let line = String(palette[lineStart ..< lineEnd])
            if !line.contains("excludedKinds: excludedKinds") { offenders.append(line.trimmingCharacters(in: .whitespaces)) }
            search = range.upperBound
        }
        #expect(storeTools == 3, "expected search + list + get over the store; found \(storeTools)")
        #expect(offenders.isEmpty, "store tools the .mcp palette would NOT withhold Photos on: \(offenders)")
    }

    @Test("the .mcp responder's source collector is its own: makeAgentResponder allocates one per call")
    func mcpResponderOwnsItsCollector() throws {
        let root = try Self.packageRoot()
        let history = try String(
            contentsOf: root.appending(path: "M1K3App/AppEnvironment+ChatHistory.swift"), encoding: .utf8
        )
        let start = try #require(history.range(of: "static func makeAgentResponder("))
        let body = String(history[start.upperBound...])
        let firstReturn = try #require(body.range(of: "return AgentRAGResponder("))
        let prologue = String(body[..<firstReturn.lowerBound])
        #expect(prologue.contains("let sourceCollector = ToolSourceCollector()"))
        #expect(!history.contains("static let sourceCollector"))
        #expect(!history.contains("static var sourceCollector"))

        let env = try String(contentsOf: root.appending(path: "M1K3App/AppEnvironment.swift"), encoding: .utf8)
        for responder in ["intelligenceResponder", "mcpResponder"] {
            let decl = try #require(env.range(of: "lazy var \(responder): any RAGResponding ="))
            let tail = String(env[decl.upperBound...].prefix(120))
            #expect(tail.contains("makeAgentResponder("), "\(responder) must build through makeAgentResponder")
        }
    }
}
