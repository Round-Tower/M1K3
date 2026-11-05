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
//

import Foundation
import Testing

struct HUDDemoScanTests {
    private static var appDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("M1K3App")
    }

    /// Lines mentioning `hudDemo` that are not inside a `#if DEBUG` region (comments are allowed anywhere).
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
            } else if !line.hasPrefix("//"), line.contains("hudDemo"), !(stack.last ?? false) {
                out.append(i + 1)
            }
        }
        return out
    }

    @Test("Every hudDemo reference in M1K3App sits inside #if DEBUG")
    func everyReferenceIsDebugOnly() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.appDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "scan found no sources: M1K3App moved")
        var sawAny = false
        for file in files {
            let src = try String(contentsOf: file, encoding: .utf8)
            if src.contains("hudDemo") { sawAny = true }
            let bad = Self.leaks(in: src)
            #expect(bad.isEmpty, "\(file.lastPathComponent) lines \(bad): hudDemo outside #if DEBUG")
        }
        #expect(sawAny, "the demo harness is gone: delete this test and hud-capture.sh together")
    }

    @Test("The scanner itself flags an unguarded reference and passes a guarded one")
    func scannerFlagsLeaks() {
        #expect(Self.leaks(in: "let a = \"hudDemo\"") == [1])
        #expect(Self.leaks(in: "#if DEBUG\nlet a = \"hudDemo\"\n#endif").isEmpty)
        #expect(Self.leaks(in: "#if DEBUG\n#else\nlet a = \"hudDemo\"\n#endif") == [3])
    }
}
