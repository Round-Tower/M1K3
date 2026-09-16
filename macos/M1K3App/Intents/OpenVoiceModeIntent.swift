//
//  OpenVoiceModeIntent.swift
//  M1K3App
//
//  "Talk to M1K3" for Siri & Shortcuts — brings M1K3 to the foreground and
//  opens voice mode. This IS the deep-OS integration seed (Kev, 2026-06-10):
//  "Hey Siri, talk to M1K3" → full-window voice conversation.
//
//  Unlike the other intents, this one opens the app (`openAppWhenRun = true`)
//  and calls enterVoiceMode() directly once the environment is warm.
//
//  App-glue (verify-by-launch). Signed: Kev + claude-opus-4-6, 2026-09-16,
//  Confidence 0.75 (the voice-mode trigger path is verify-by-launch),
//  Prior: SpeakWithM1K3Intent
//

import AppIntents

struct OpenVoiceModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to M1K3"
    static let description = IntentDescription(
        "Open M1K3 in voice mode for a live conversation.",
        categoryName: "Voice"
    )
    static let openAppWhenRun = true

    static var parameterSummary: some ParameterSummary {
        Summary("Talk to M1K3")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let env = try await M1K3IntentSupport.environment()
        env.requestVoiceMode()
        return .result()
    }
}
