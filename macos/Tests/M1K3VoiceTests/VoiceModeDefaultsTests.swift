//
//  VoiceModeDefaultsTests.swift
//  M1K3VoiceTests
//

import Foundation
import M1K3Voice
import Testing

struct VoiceModeDefaultsTests {
    @Test("the key literal is pinned — it is already on disk in every install")
    func keyIsStable() {
        // The Mac shell has written this exact string since 2026-06-11. Changing
        // it doesn't just lose a preference: a live voice session would stop
        // being recognised as one halfway through an upgrade.
        #expect(VoiceModeDefaults.activeKey == "voiceMode.active")
    }

    @Test("an absent key reads as NOT in voice mode")
    func absentReadsFalse() {
        let defaults = UserDefaults.standard
        let restore = defaults.object(forKey: VoiceModeDefaults.activeKey)
        defer { defaults.set(restore, forKey: VoiceModeDefaults.activeKey) }

        defaults.removeObject(forKey: VoiceModeDefaults.activeKey)
        // The safe direction: a missed spoken turn costs latency; a typed turn
        // wrongly treated as spoken loses grounding the reader could have used.
        #expect(!VoiceModeDefaults.isActive)
    }

    @Test("the launch reset clears a flag left set by a crash mid-conversation")
    func launchResetClears() {
        let defaults = UserDefaults.standard
        let restore = defaults.object(forKey: VoiceModeDefaults.activeKey)
        defer { defaults.set(restore, forKey: VoiceModeDefaults.activeKey) }

        defaults.set(true, forKey: VoiceModeDefaults.activeKey)
        VoiceModeDefaults.resetAtLaunch()
        // Both shells call this. A survivor `true` would apply spoken grounding
        // budgets to every TYPED turn until the user next entered and left voice
        // mode — invisible, and only on the installs that had already crashed.
        #expect(!VoiceModeDefaults.isActive)
    }

    @Test("the flag reads back what was written")
    func readsWhatWasWritten() {
        let defaults = UserDefaults.standard
        let restore = defaults.object(forKey: VoiceModeDefaults.activeKey)
        defer { defaults.set(restore, forKey: VoiceModeDefaults.activeKey) }

        defaults.set(true, forKey: VoiceModeDefaults.activeKey)
        #expect(VoiceModeDefaults.isActive)
        defaults.set(false, forKey: VoiceModeDefaults.activeKey)
        #expect(!VoiceModeDefaults.isActive)
    }

    @Test("the auto-speak key is pinned and defaults OFF")
    func autoSpeakKeyPinnedAndDefaultsOff() {
        #expect(VoiceModeDefaults.autoSpeakKey == "chat.autoSpeak")

        let defaults = UserDefaults.standard
        let restore = defaults.object(forKey: VoiceModeDefaults.autoSpeakKey)
        defer { defaults.set(restore, forKey: VoiceModeDefaults.autoSpeakKey) }

        defaults.removeObject(forKey: VoiceModeDefaults.autoSpeakKey)
        // Speaking every answer unprompted is an opt-in, never a surprise.
        #expect(!VoiceModeDefaults.autoSpeakEnabled)
        defaults.set(true, forKey: VoiceModeDefaults.autoSpeakKey)
        #expect(VoiceModeDefaults.autoSpeakEnabled)
    }
}
