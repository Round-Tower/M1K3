//
//  HUDDemoScanTests.swift
//  M1K3AvatarTests
//
//  Source-scan tripwire: the HUD demo launch args (`-hudDemo`, `-hudDemoScreen`, `-hudDemoText`) are a
//  Debug-only capture harness (tools/screengrab/direct/hud-capture.sh). Every `hudDemo` reference in
//  M1K3App must sit inside `#if DEBUG`, so a Release build carries none of it.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-05, Confidence 0.75 (text scan; nesting is tracked by
//  #if/#endif depth, and an `#else` branch counts as outside DEBUG). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-05 — review fold: scan also HUDDemoConfig/startDemo, case-insensitive,
//  recursive; require the live call site in M1K3App.swift; NotchHUDDemo.swift must be wholly #if DEBUG. Confidence 0.8.
//

import Foundation
import Testing

struct HUDDemoScanTests {
    private static var appDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("M1K3App")
    }

    /// Lowercased: matches the argv keys (`hudDemo…`), `HUDDemoConfig` and `startDemo` alike.
    private static let needles = ["huddemo", "startdemo"]

    /// True when the first code line is `#if DEBUG` and the last is `#endif` (comments and blanks skipped).
    static func isWhollyDebug(_ source: String) -> Bool {
        let code = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        return code.first == "#if DEBUG" && code.last == "#endif"
    }

    /// Lines mentioning the demo (see `needles`) that are not inside a `#if DEBUG` region (comments are allowed anywhere).
    static func leaks(in source: String) -> [Int] {
        var stack: [Bool] = [] // true while the innermost region is a live DEBUG branch
        var out: [Int] = []
        for (i, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if") {
                stack.append(line == "#if DEBUG" || ((stack.last ?? false) && !line.hasPrefix("#if !")))
            } else if line.hasPrefix("#else") || line.hasPrefix("#elseif") {
                if !stack.isEmpty { stack[stack.count - 1] = false }
            } else if line.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
            } else if !line.hasPrefix("//"), needles.contains(where: { line.lowercased().contains($0) }),
                      !(stack.last ?? false)
            {
                out.append(i + 1)
            }
        }
        return out
    }

    @Test("Every hudDemo reference in M1K3App sits inside #if DEBUG")
    func everyReferenceIsDebugOnly() throws {
        let walker = FileManager.default.enumerator(at: Self.appDir, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "scan found no sources: M1K3App moved")
        var sawCallSite = false
        for file in files {
            let src = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent == "M1K3App.swift", src.contains("HUDDemoConfig") { sawCallSite = true }
            let bad = Self.leaks(in: src)
            #expect(bad.isEmpty, "\(file.lastPathComponent) lines \(bad): hudDemo outside #if DEBUG")
        }
        #expect(sawCallSite, "the demo call site in M1K3App.swift is gone: delete this test and hud-capture.sh together")
    }

    @Test("The scanner itself flags an unguarded reference and passes a guarded one")
    func scannerFlagsLeaks() {
        #expect(Self.leaks(in: "let a = \"hudDemo\"") == [1])
        #expect(Self.leaks(in: "#if DEBUG\nlet a = \"hudDemo\"\n#endif").isEmpty)
        #expect(Self.leaks(in: "#if DEBUG\n#else\nlet a = \"hudDemo\"\n#endif") == [3])
    }

    @Test("The live call site's type and method names are scanned, not just the argv keys")
    func scannerSeesCallSite() {
        #expect(Self.leaks(in: "let c = HUDDemoConfig.fromLaunchArguments()") == [1])
        #expect(Self.leaks(in: "hud.startDemo(demo)") == [1])
        #expect(Self.leaks(in: "#if DEBUG\nhud.startDemo(demo)\n#endif").isEmpty)
        #expect(Self.leaks(in: "// HUDDemoConfig is Debug-only").isEmpty)
    }

    @Test("A whole-file DEBUG guard is recognised by its first and last code lines")
    func framingCheck() {
        #expect(Self.isWhollyDebug("//  header\n\n#if DEBUG\nlet a = 1\n#endif\n"))
        #expect(!Self.isWhollyDebug("let a = 1\n#if DEBUG\nlet b = 2\n#endif\n"))
        #expect(!Self.isWhollyDebug("#if DEBUG\nlet a = 1\n#endif\nlet b = 2\n"))
    }

    @Test("NotchHUDDemo.swift is wholly #if DEBUG")
    func demoFileIsWhollyDebug() throws {
        let src = try String(contentsOf: Self.appDir.appendingPathComponent("NotchHUDDemo.swift"), encoding: .utf8)
        #expect(Self.isWhollyDebug(src))
    }
}
