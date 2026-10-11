//
//  ChatChromeScanTests.swift
//  M1K3AvatarTests
//
//  Source-scan pins on the 1.1 chat chrome (Kev, 2026-10-11, TestFlight): no thinking rain
//  behind the avatar, no avatar panel, the Review toggle at the toolbar's right edge. The
//  views have no pure seam, so these read the shell files from disk (VoiceModeFloorTests
//  idiom) and match on strings, not line numbers.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.6 (coarse tripwires; the look is
//  verify-by-launch). Prior: none (new file).
//

import Foundation
import Testing

struct ChatChromeScanTests {
    /// Source with comment lines stripped, so headers may explain what was removed.
    private static func code(_ relative: String) throws -> String {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(!src.isEmpty, "scan read an empty file — \(relative) moved")
        return src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("no shell view mounts the thinking rain",
          arguments: ["M1K3App/VoiceModeView.swift", "M1K3App/AvatarChatBackground.swift", "M1K3App/ContentView.swift"])
    func noThinkingRain(_ path: String) throws {
        let code = try Self.code(path)
        #expect(!code.contains("InferencePhosphorView("), "\(path) mounts the thinking rain again")
        #expect(!code.contains("showsInferenceRain"), "\(path) still has the rain flag")
    }

    @Test("the avatar panel is gone")
    func noAvatarPanel() throws {
        let code = try Self.code("M1K3App/ContentView.swift")
        #expect(code.contains("struct ContentView"), "scan is not reading ContentView")
        #expect(!code.contains("avatarPanel"), "the avatar panel is back")
        #expect(!code.contains("== .panel"), "a panel avatar mode is back")
    }

    @Test("the Review toggle is the last toolbar item, after the chat items and a fixed spacer")
    func reviewToggleIsRightmost() throws {
        let code = try Self.code("M1K3App/ContentView.swift")
        let group = try #require(code.range(of: "chatToolbarItems\n"), "the chat items group moved")
        let spacer = try #require(code.range(of: "ToolbarSpacer(.fixed"), "no fixed spacer before Review")
        let review = try #require(code.range(of: "reviewPanelToolbarItem"), "no Review toolbar item")
        #expect(group.lowerBound < spacer.lowerBound, "the spacer is not after the chat items")
        #expect(spacer.lowerBound < review.lowerBound, "Review is not after the spacer")
    }
}
