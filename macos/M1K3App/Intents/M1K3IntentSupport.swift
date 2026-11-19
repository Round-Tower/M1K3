//
//  M1K3IntentSupport.swift
//  M1K3App
//
//  Shared plumbing for the App Intents (Ask · Speak · Remember). An intent's
//  perform() runs outside SwiftUI's @Environment, so it reaches the live, warm
//  AppEnvironment through the launch-time registry (AppEnvironment+Intelligence).
//  M1K3 is normally menu-bar-resident, so the wait below only bites on a cold
//  background launch — in which case the intent surfaces a friendly "open me once"
//  rather than hanging.
//
//  App-glue (verify-by-launch): the testable input handling is IntentInput
//  (M1K3Chat); the answer/speak/remember logic is AppEnvironment+Intelligence.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.78, Prior: Unknown
//  Review: claude-opus-5-5, 2026-11-19 — l10n phase 0: the "isn't ready yet" error is String(localized:);
//  an MCPVoiceError's text stays English (the same text is MCP wire output an agent reads).
//

import Foundation
import M1K3MCPKit // MCPVoiceError — mapped to a user-facing message

/// A user-facing intent failure. Conforms to `LocalizedError` so Siri/Shortcuts
/// shows the message verbatim instead of a generic "operation couldn't be completed".
struct M1K3IntentError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

enum M1K3IntentSupport {
    /// How long an intent waits for the environment to come up before giving up.
    /// M1K3 launches at login and lives in the menu bar, so it's normally already
    /// resident; this only matters when an intent cold-launches the app in the
    /// background.
    static let environmentWait: Double = 12

    /// The live environment, or a friendly error if M1K3 isn't up in time.
    @MainActor
    static func environment() async throws -> AppEnvironment {
        guard let env = await AppEnvironment.current(waitingUpTo: environmentWait) else {
            throw M1K3IntentError(message: String(
                localized: "M1K3 isn’t ready yet. Open M1K3 once, then try again.",
                comment: "Siri/Shortcuts error when the app is not running in time. M1K3 is the app name."
            ))
        }
        return env
    }

    /// Map the shared surface's `MCPVoiceError` (not-ready / busy / timeout) onto a
    /// user-facing message. Everything else — including `IntentInput.EmptyInput`,
    /// which is already a `LocalizedError` — propagates unchanged.
    static func surface(_ error: Error) -> Error {
        if let voiceError = error as? MCPVoiceError {
            return M1K3IntentError(message: voiceError.description)
        }
        return error
    }
}
