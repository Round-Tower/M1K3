//
//  StatedStyleWiringTests.swift
//  M1K3ChatTests
//
//  #699: the stated style reaches the persona through app-target wiring `swift test` cannot
//  run, so it is pinned by reading the source (the AskSurfaceCallSiteTests and
//  ChatEvalStageWiringTests idiom). Pinned: the style is re-read at launch, after a
//  distillation that wrote, and at `refreshCounts()`, the one seam every memory write and
//  forget already calls (the Memories list's, and MCP forget_memory's, which had no re-read:
//  a forgotten ask rode every prompt until relaunch). Every graph forget in the app is
//  followed by that seam. The edit goes through the tested `MemoryEditor`. The PCC eval
//  column skips while a style is set, before anything is sent.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.8 (a text scan: a rename of the
//  functions or calls must update the anchors here, and each anchor is asserted to exist
//  first), Prior: none (new file)
//

import Foundation
import Testing

struct StatedStyleWiringTests {
    private static func appSource(_ file: String) throws -> String {
        var root = URL(filePath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root = root.deletingLastPathComponent()
            try #require(root.path != "/", "no Package.swift above \(#filePath)")
        }
        return try code(String(contentsOf: root.appending(path: "M1K3App/\(file)"), encoding: .utf8))
    }

    /// The source without its `//` comment lines, so a doc mentioning a call can't satisfy a scan.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The text from `head` to the next `func ` declaration.
    private static func body(of head: String, in text: String) throws -> Substring {
        let start = try #require(text.range(of: head), "anchor missing: \(head)")
        let rest = text[start.upperBound...]
        let next = rest.range(of: "func ")?.lowerBound ?? rest.endIndex
        return rest[..<next]
    }

    @Test("refreshCounts, the seam every memory write and forget calls, re-reads the stated style")
    func refreshCountsReReadsTheStyle() throws {
        let body = try Self.body(of: "func refreshCounts()", in: Self.appSource("AppEnvironment.swift"))
        #expect(body.contains("refreshUserStyle()"))
    }

    @Test("the style survives a relaunch: startup maintenance restores it beside the profile")
    func launchRestoresTheStyle() throws {
        let body = try Self.body(of: "func runStartupMaintenance()", in: Self.appSource("AppEnvironment.swift"))
        let profile = try #require(body.range(of: "M1K3Persona.setUserProfile("))
        let style = try #require(body.range(of: "refreshUserStyle()"))
        #expect(profile.lowerBound < style.lowerBound)
    }

    @Test("a distillation that wrote re-reads the style: the hook is wired and forwarded")
    func distillationHookIsWired() throws {
        let env = try Self.appSource("AppEnvironment.swift")
        let call = try #require(env.range(of: "distillation: Self.makeMemoryDistillation("))
        let hook = try #require(env[call.upperBound...].range(of: "didWrite:"))
        let line = env[hook.lowerBound...].prefix { $0 != "\n" }
        #expect(line.contains("Self.refreshUserStyle(from: memoryStore)"))

        let factory = try Self.body(
            of: "static func makeMemoryDistillation(", in: Self.appSource("AppEnvironment+ChatHistory.swift")
        )
        #expect(factory.contains("didWrite: didWrite"))
    }

    @Test("every graph forget in the app is followed by refreshCounts, so a forgotten ask leaves the persona")
    func everyForgetRefreshes() throws {
        let files = ["AppEnvironment+Memory.swift", "MCPHostController.swift"]
        var forgets = 0
        for file in files {
            let lines = try Self.appSource(file).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard line.contains("memoryStore.forget(id:") || line.contains("editor.forget(") else { continue }
                forgets += 1
                let after = lines[index ..< min(index + 25, lines.count)].joined(separator: "\n")
                #expect(after.contains("refreshCounts()"), "\(file):\(index + 1) forgets without a refresh")
            }
        }
        #expect(forgets >= 2) // the Memories list's forget and MCP forget_memory
    }

    @Test("the Memories edit and forget go through the tested MemoryEditor, and the list shows every style row")
    func memoriesSurfaceUsesTheEditor() throws {
        let source = try Self.appSource("AppEnvironment+Memory.swift")
        #expect(try Self.body(of: "func editMemory(", in: source).contains("editor.edit(memory.id"))
        #expect(try Self.body(of: "func forgetMemory(", in: source).contains("editor.forget(memory.id)"))
        #expect(source.contains("MemoryEditor(graph:"))
        #expect(try Self.body(of: "func memories(", in: source).contains("reviewableMemories("))
    }

    @Test("the PCC eval column checks the stated style before it sends anything")
    func pccColumnSkipsWhileAStyleIsSet() throws {
        let body = try Self.body(
            of: "private static func evalPrivateCloud(", in: Self.appSource("ChatEvalStage.swift")
        )
        let guardStyle = try #require(body.range(of: "M1K3Persona.userStyle.isEmpty"))
        let send = try #require(body.range(of: "evalProvider("))
        #expect(guardStyle.lowerBound < send.lowerBound)
    }
}
