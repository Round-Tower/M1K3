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
