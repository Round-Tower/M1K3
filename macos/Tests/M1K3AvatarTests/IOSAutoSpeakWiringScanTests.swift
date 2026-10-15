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

    @Test("spoken answers play under the readout's speech session (muted phone heard, music ducked), released after")
    func audioSession() throws {
        let auto = try Self.code("M1K3iOSApp/AppCore+AutoSpeak.swift")
        // One copy of the session config: the readout's / sample's activate and voice mode's deactivate.
        #expect(auto.contains("await Self.activateSampleAudioSession()"))
        #expect(auto.contains("Self.deactivateVoiceAudioSession()"))
        #expect(!auto.contains("setCategory("))
        let output = try Self.code("M1K3iOSApp/AppCore+VoiceOutput.swift")
        #expect(output.contains("setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])"))
        // An earcon between two sentences must not flip the session back to ambient mid-answer.
        let core = try Self.code("M1K3iOSApp/AppCore.swift")
        #expect(core.contains("guard voiceLoop == nil, autoSpeakTask == nil else { return }"))
    }

    @Test("an auto-spoken answer keeps its session between sentences: the utterance-end release asks the policy")
    func sessionHeldBetweenSentences() throws {
        // Each sentence is one utterance, so onSpeakingEnded fires between two sentences. The rule (release unless
        // voice mode has the session or an answer holds it) is AnswerAudioSessionPolicyTests.utteranceEnd; this pins
        // that the shell asks it, with the hold an answer takes at its first sentence, before releasing.
        let voice = try Self.code("M1K3iOSApp/AppCore+Voice.swift")
        let ended = try #require(voice.components(separatedBy: "speech.onSpeakingEnded = {").dropFirst().first)
        let block = ended.components(separatedBy: "speech.onTimelineReady").first ?? ""
        let askAt = try #require(
            block.range(of: "AnswerAudioSessionPolicy.releaseWhenUtteranceEnds("), "the release ignores auto-speak"
        )
        #expect(block.contains("answerHoldsSession: answerAudioHeld"))
        let releaseAt = try #require(block.range(of: "deactivateVoiceAudioSession()"))
        #expect(askAt.lowerBound < releaseAt.lowerBound)
    }

    @Test("a session's end is generation-owned and asks the policy; the duck starts at the first sentence")
    func sessionOwnership() throws {
        // The rule is AnswerAudioSessionPolicyTests.answerEnd; these pin the shell's half of it.
        let auto = try Self.code("M1K3iOSApp/AppCore+AutoSpeak.swift")
        let begin = try #require(auto.components(separatedBy: "func beginAutoSpeakSession()").dropFirst().first)
        // Every session gets its own generation, and its defer hands that generation to the end handler.
        #expect(begin.contains("autoSpeakGeneration += 1"))
        #expect(begin.contains("defer { self?.autoSpeakSessionEnded(generation: generation) }"))
        // No activation at the start of the session: the first sentence takes it.
        let loopAt = try #require(begin.range(of: "while !Task.isCancelled"))
        #expect(!begin[..<loopAt.lowerBound].contains("activateSampleAudioSession"))
        #expect(begin[..<loopAt.lowerBound].contains("await self?.releaseAnswerAudio()"))
        let sentence = try #require(auto.components(separatedBy: "func speakAnswerSentence(").dropFirst().first)
        let holdAt = try #require(sentence.range(of: "answerAudioHeld = true"))
        let activateAt = try #require(sentence.range(of: "await Self.activateSampleAudioSession()"))
        #expect(holdAt.lowerBound < activateAt.lowerBound)
        // The end: only the current generation touches Stop and the session, and the release asks the policy.
        let ended = try #require(
            auto.components(separatedBy: "func autoSpeakSessionEnded(generation: Int)").dropFirst().first
        )
        #expect(ended.contains("generation == autoSpeakGeneration"))
        #expect(ended.contains("AnswerAudioSessionPolicy.releaseWhenAnswerEnds("))
        let guardAt = try #require(ended.range(of: "guard isCurrent else { return }"))
        let stopFaceAt = try #require(ended.range(of: "isSpeakingAnswer = false"))
        #expect(guardAt.lowerBound < stopFaceAt.lowerBound)
    }

    @Test("both auto-speak loops (phone and Mac) skip a sentence that polishes to nothing, never read it raw")
    func trailerSentenceSkipped() throws {
        // The pure rule is SpeechTextPolishTests.trailerSentenceIsSilent; this pins that both shells use it.
        let phone = try Self.code("M1K3iOSApp/AppCore+AutoSpeak.swift")
        #expect(phone.contains("guard let spoken = SpeechTextPolish.spokenSentence(text) else { return }"))
        #expect(!phone.contains("polished.isEmpty ? text : polished"))
        let mac = try Self.code("M1K3App/AppEnvironment+AutoSpeak.swift")
        #expect(mac.contains("guard let spoken = SpeechTextPolish.spokenSentence(sentence) else { continue }"))
        #expect(mac.contains("let spoken = folder.flush().flatMap(SpeechTextPolish.spokenSentence)"))
        #expect(!mac.contains("await self.speak(sentence)"))
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
