//
//  IOSVoiceModeLeakGuardScanTests.swift
//  M1K3AvatarTests
//
//  iPhone voice mode built its StreamedAnswerFolder with no leak guard, so a leaked prompt streamed into the bubble
//  was read aloud before ChatSession's end-of-turn guard swapped the text; and it lacked the Mac's settled-refusal
//  fallback, so a leak swapped between two polls ended the turn silent. The Mac (AppEnvironment+VoiceMode) and
//  iPhone auto-speak already had both. These text tripwires pin the phone's voice loop to the same shape; the
//  rules themselves are StreamedAnswerFolderTests and ChatSessionLeakGuardTests.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02, Confidence 0.7 (text tripwires; the spoken refusal is
//  verify-on-device). Prior: Unknown.
//

import Foundation
import Testing

struct IOSVoiceModeLeakGuardScanTests {
    private static func code(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The phone's voice-mode turn: from its streaming closure to the end of the closure's success return.
    private static func voiceTurn() throws -> String {
        let voice = try code("M1K3iOSApp/AppCore+Voice.swift")
        let turn = try #require(voice.components(separatedBy: "runTurnStreaming: {").dropFirst().first)
        return turn.components(separatedBy: "// MARK: - Serialized speak").first ?? turn
    }

    @Test("the phone's voice-mode folder carries the persona leak guard, like the Mac's and auto-speak's")
    func folderIsGuarded() throws {
        let turn = try Self.voiceTurn()
        let folderAt = try #require(turn.range(of: "var folder = StreamedAnswerFolder("))
        #expect(turn[folderAt.lowerBound...].prefix(300).contains("leakGuard: Self.spokenLeakGuard"))
        // One guard definition on the phone (AppCore+AutoSpeak), the live predicate and refusal.
        let auto = try Self.code("M1K3iOSApp/AppCore+AutoSpeak.swift")
        #expect(auto.contains("static let spokenLeakGuard"))
        #expect(auto.contains("PersonaLeakGuard.leaks($0)"))
    }

    @Test("a refusal swapped in between two polls is spoken, before the flush, as on the Mac")
    func settledRefusalSpoken() throws {
        let turn = try Self.voiceTurn()
        let settledAt = try #require(turn.range(of: "foldForward(settled.text)"))
        let fallbackAt = try #require(
            turn.range(of: "if !folder.tripped, settled.text == PersonaLeakGuard.refusal {"),
            "the phone's voice mode has no settled-refusal fallback"
        )
        let flushAt = try #require(turn.range(of: "folder.flush()"))
        #expect(settledAt.lowerBound < fallbackAt.lowerBound)
        #expect(fallbackAt.lowerBound < flushAt.lowerBound)
        #expect(turn[fallbackAt.lowerBound...].prefix(200).contains("onChunk(PersonaLeakGuard.refusal)"))
    }
}
