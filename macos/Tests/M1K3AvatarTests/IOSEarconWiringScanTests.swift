//
//  IOSEarconWiringScanTests.swift
//  M1K3AvatarTests
//
//  Kev, iPhone list 2026-10-12: "Sound effects & earcons". The catalogue, the synth recipes and the player
//  are shared (M1K3Avatar, pinned by SoundEffectPlayerTests / EarconSynthTests); the iPhone shell had none of
//  them wired. These read the shell from disk (the OnboardingDeckScanTests idiom) because the wiring is SwiftUI
//  + AVAudioSession with no pure seam; how the sounds land is verify-on-device.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-12, Confidence 0.6 (text tripwires; the sound is verify-on-device).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-12 — voice mode's start is the onboarding chime now (VoiceModeEarcons), and the
//  earcon session guard also waits out an auto-spoken answer. Confidence 0.6.
//  Review: Kev + claude-opus-5.5, 2026-10-15 — a turn's earcon is one helper (`playTurnEarcon`) shared by the local
//  and Private Cloud sends; the pin follows it. Confidence 0.6.
//

import Foundation
import Testing

struct IOSEarconWiringScanTests {
    private static func code(_ relative: String) throws -> String {
        // …/macos/Tests/M1K3AvatarTests/<this file>
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("the shared factory runs a beforePlay hook ahead of each one-shot (the iPhone's session choice)")
    func factoryHook() throws {
        let player = try Self.code("Sources/M1K3Avatar/SoundEffectPlayer.swift")
        #expect(player.contains("beforePlay: @escaping @MainActor () -> Void = {}"))
        #expect(player.contains("sink: { effect in beforePlay(); pool.play(effect) }"))
    }

    @Test("the iPhone builds the player with the Mac's key and volume, and plays ambient outside voice mode")
    func playerAndSession() throws {
        let core = try Self.code("M1K3iOSApp/AppCore.swift")
        #expect(core.contains("static let soundEffectsEnabledKey = \"soundEffects.enabled\""))
        #expect(core.contains("lazy var soundEffects: SoundEffectPlayer = .bundled("))
        #expect(core.contains("volume: 0.3"))
        #expect(core.contains("beforePlay: { [weak self] in self?.prepareEarconSession() }"))
        // Ambient mixes with the user's music and honours the silent switch; voice mode keeps its own session.
        #expect(core.contains("guard voiceLoop == nil, autoSpeakTask == nil else { return }"))
        #expect(core.contains("setCategory(.ambient, mode: .default, options: [.mixWithOthers])"))
    }

    @Test("the moments: a typed answer or failure, voice mode's four, and onboarding's ticks and done chord")
    func moments() throws {
        let core = try Self.code("M1K3iOSApp/AppCore.swift")
        let send = core.components(separatedBy: "func send(_ text: String").dropFirst().first ?? ""
        // Both send paths (local and Private Cloud) share one helper; send() asks it.
        #expect(send.prefix(1500).contains("playTurnEarcon(answer)"))
        let earcon = core.components(separatedBy: "private func playTurnEarcon(").dropFirst().first ?? ""
        #expect(earcon.contains("soundEffects.play(.error)") && earcon.contains("soundEffects.play(.answerLanded)"))
        let voice = try Self.code("M1K3iOSApp/AppCore+Voice.swift")
        // Voice mode opens on the onboarding's chime (VoiceModeEarcons, pinned in VoiceModeEarconsTests).
        for effect in ["VoiceModeEarcons.enter", ".voiceExit", ".endpointHeard"] {
            #expect(voice.contains("soundEffects.play(\(effect))"), "voice mode lost \(effect)")
        }
        #expect(voice.contains("VoiceModeEarcons.listenStart(isFirstListen:"))
        let onboarding = try Self.code("M1K3iOSApp/OnboardingScreen.swift")
        #expect(onboarding.contains("core.soundEffects.play(.selectionTick)"))
        #expect(onboarding.contains("core.soundEffects.play(.doneChord)"))
    }

    @Test("Settings has the toggle, and it reaches the live player")
    func toggle() throws {
        let section = try Self.code("M1K3iOSApp/VoiceOutputSection.swift")
        #expect(section.contains("@AppStorage(AppCore.soundEffectsEnabledKey)"))
        #expect(section.contains("Toggle(\"Sound effects\""))
        #expect(section.contains("core.soundEffects.isEnabled = enabled"))
    }
}
