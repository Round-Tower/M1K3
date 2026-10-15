//
//  IOSAutoSpeakWiringScanTests.swift
//  M1K3AvatarTests
//
//  Kev, 2026-10-12: "auto voice on iOS, so voice on with Kokoro". The Mac's chat auto-speak, on the iPhone:
//  answers spoken sentence by sentence as they stream, in the chosen voice (M1K3 Voice is Kokoro), with the
//  same key ("chat.autoSpeak") and the same shared seams (StreamedAnswerFolder, the persona leak guard). The
//  felt beat is verify-on-device; these pin the wiring.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-12, Confidence 0.6 (text tripwires). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-15 — `sessionHeldBetweenSentences`: master's #597 follow-up releases the
//  audio session whenever speech ends outside voice mode, and an auto-spoken answer ends one utterance per sentence,
//  so that release must wait while auto-speak holds the session. Confidence 0.6 (a text tripwire; verify-by-ear).
//

import Foundation
import Testing

struct IOSAutoSpeakWiringScanTests {
    private static func code(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("a session starts before the send, never in voice mode, and folds with the leak guard")
    func session() throws {
        let auto = try Self.code("M1K3iOSApp/AppCore+AutoSpeak.swift")
        #expect(auto.contains("VoiceModeDefaults.autoSpeakEnabled && voiceLoop == nil"))
        #expect(auto.contains("leakGuard: Self.spokenLeakGuard"))
        #expect(auto.contains("PersonaLeakGuard.leaks($0)"))
        let core = try Self.code("M1K3iOSApp/AppCore.swift")
        let send = core.components(separatedBy: "func send(_ text: String").dropFirst().first ?? ""
        let beginAt = try #require(send.range(of: "beginAutoSpeakSession()"))
        let sendAt = try #require(send.range(of: "await chat.send("))
        #expect(beginAt.lowerBound < sendAt.lowerBound)
    }

    @Test("spoken answers get a speech session (heard on a muted phone, music ducked), released after")
    func audioSession() throws {
        let auto = try Self.code("M1K3iOSApp/AppCore+AutoSpeak.swift")
        #expect(auto.contains("setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])"))
        #expect(auto.contains("setActive(false, options: .notifyOthersOnDeactivation)"))
        // An earcon between two sentences must not flip the session back to ambient mid-answer.
        let core = try Self.code("M1K3iOSApp/AppCore.swift")
        #expect(core.contains("guard voiceLoop == nil, autoSpeakTask == nil else { return }"))
    }

    @Test("an auto-spoken answer keeps its session between sentences: only the answer's own end releases it")
    func sessionHeldBetweenSentences() throws {
        // Each sentence is one utterance, so onSpeakingEnded fires between two sentences. Its release (for a readout
        // or a sample) waits while auto-speak holds the session, or ducked music swells back between sentences and the
        // next one starts on a session that was just deactivated.
        let voice = try Self.code("M1K3iOSApp/AppCore+Voice.swift")
        let ended = try #require(voice.components(separatedBy: "speech.onSpeakingEnded = {").dropFirst().first)
        let block = ended.components(separatedBy: "speech.onTimelineReady").first ?? ""
        let guardAt = try #require(block.range(of: "if autoSpeakTask == nil"), "the release ignores auto-speak")
        let releaseAt = try #require(block.range(of: "deactivateVoiceAudioSession()"))
        #expect(guardAt.lowerBound < releaseAt.lowerBound)
    }

    @Test("stop and leaving the app end it; Settings has the switch on the shared key")
    func stops() throws {
        let core = try Self.code("M1K3iOSApp/AppCore.swift")
        let stop = core.components(separatedBy: "func stopResponding()").dropFirst().first ?? ""
        #expect(stop.prefix(400).contains("cancelAutoSpeak()"))
        let app = try Self.code("M1K3iOSApp/M1K3iOSHarnessApp.swift")
        #expect(app.contains("core?.cancelAutoSpeak()"))
        let section = try Self.code("M1K3iOSApp/VoiceOutputSection.swift")
        #expect(section.contains("@AppStorage(VoiceModeDefaults.autoSpeakKey)"))
        #expect(section.contains("Toggle(\"Speak answers\""))
    }
}
