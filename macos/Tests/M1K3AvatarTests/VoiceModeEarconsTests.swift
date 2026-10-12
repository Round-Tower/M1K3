//
//  VoiceModeEarconsTests.swift
//  M1K3AvatarTests
//
//  Kev, 2026-10-12 (iPhone): "the Voice sound effects on start, can we use our new onboarding sound instead".
//  Voice mode opens on the onboarding's wake chime, and that first listen skips its mic-open tick (the chime
//  already said it; the two used to land ~0.5 s apart). Every later listen keeps the tick. Both shells.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-12, Confidence 0.85. Prior: none (new file).
//

import Foundation
@testable import M1K3Avatar
import Testing

struct VoiceModeEarconsTests {
    @Test("voice mode opens on the onboarding's wake chime")
    func enter() {
        #expect(VoiceModeEarcons.enter == .wakeChime)
    }

    @Test("the first listen after the chime is silent; every later one ticks")
    func listenStart() {
        #expect(VoiceModeEarcons.listenStart(isFirstListen: true) == nil)
        #expect(VoiceModeEarcons.listenStart(isFirstListen: false) == .listenStart)
    }

    @Test("both shells play the policy, not the raw cases")
    func shells() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["M1K3iOSApp/AppCore+Voice.swift", "M1K3App/AppEnvironment+VoiceMode.swift"] {
            let code = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(code.contains("soundEffects.play(VoiceModeEarcons.enter)"), "\(file) lost the chime")
            #expect(code.contains("VoiceModeEarcons.listenStart(isFirstListen:"), "\(file) ticks on every listen")
            #expect(!code.contains("soundEffects.play(.voiceEnter)"), "\(file) still plays the old sweep")
        }
    }
}
