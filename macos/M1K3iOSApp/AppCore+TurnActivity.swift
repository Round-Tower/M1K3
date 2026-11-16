//
//  AppCore+TurnActivity.swift
//  M1K3iOS
//
//  The hooks that let the Live Activity follow a typed turn (a send, a read, a look, a Private Cloud
//  send): `beginTurnActivity` before the brain is asked, `endTurnActivity` once the turn settles. The
//  rules are TurnActivityPolicy's; the ActivityKit effects are TurnActivityDriver's (M1K3Chat; adapters in TurnActivityController.swift).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.7 (compile-checked; owes a try on a phone),
//  Prior: none (new file).

import Foundation
import M1K3Chat
import M1K3Inference
import M1K3LiveActivity
import M1K3LogCore

extension AppCore {
    /// Start following the turn about to run. False when another turn already holds the stage (a second
    /// send that will bounce off `isResponding`), and then the caller must not `endTurnActivity` either.
    func beginTurnActivity(_ kind: TurnKind) -> Bool {
        guard !chat.isResponding else { return false }
        turnActivity.turnBegan(kind: kind) { [weak self] in
            guard let self else { return .thinking }
            let waiting: TurnActivityPhase = kind == .read ? .reading : .thinking
            // Only THIS turn's streaming row counts: an earlier answer is never "answering" now.
            guard let last = chat.messages.last, last.role == .assistant, last.status == .streaming else { return waiting }
            return last.text.isEmpty ? waiting : .answering
        }
        return true
    }

    /// The turn settled (or never started: pass `.stopped`). Reads how it ended off the transcript unless told.
    func endTurnActivity(_ owned: Bool, outcome: TurnActivityPolicy.Outcome? = nil) {
        guard owned else { return }
        turnActivity.turnFinished(outcome ?? transcriptOutcome())
    }

    /// The app is leaving: the driver says Paused for an answer the exit stops (on its own short background
    /// task) and holds a grace for one that runs elsewhere. Same inputs as `BackgroundExitPolicy.stopsTurn`.
    func turnActivityLeavingForBackground(brainRunsOnThisDevicesGPU: Bool) {
        turnActivity.leavingForBackground(
            turnInFlight: chat.isResponding, brainRunsOnThisDevicesGPU: brainRunsOnThisDevicesGPU
        )
    }

    /// The scene went inactive (still foreground). Starts the card for a turn in flight and logs the decision, so
    /// the phone's console says why a card did or did not appear (the effect logs the phase, or the refusal).
    func turnActivityGoingInactive() {
        let log = M1K3Log.logger(.iosCore)
        switch turnActivity.leavingForeground() {
        case .started: log.notice("live activity: leaving mid-turn → start")
        case .alreadyShown: log.notice("live activity: leaving mid-turn → already shown")
        case .disabled: log.notice("live activity: leaving mid-turn → switched off, no card")
        case .noTurn: break // an idle pull-down is not worth a line
        }
    }

    private func transcriptOutcome() -> TurnActivityPolicy.Outcome {
        guard let last = chat.messages.last, last.role == .assistant else { return .stopped }
        if case .failed = last.status { return .failed }
        return last.interrupted == true ? .stopped : .answered
    }
}
