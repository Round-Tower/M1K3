//
//  TurnActivityCopy.swift
//  M1K3LiveActivityExtension
//
//  The words and symbols for each phase, in one place so the Lock Screen and the Dynamic Island
//  say the same thing. Fixed, app-written strings: nothing about the turn itself (its question,
//  a file's name, any answer text) can reach this surface (`TurnActivityState` has no field for it).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.75 (words by feel; the look on a real
//  phone is verify-on-device), Prior: none (new file).

import M1K3LiveActivity

struct TurnActivityCopy {
    let phase: TurnActivityPhase

    /// The headline: also the VoiceOver label.
    var title: String {
        switch phase {
        case .thinking: String(localized: "M1K3 is thinking…")
        case .reading: String(localized: "M1K3 is reading…")
        case .answering: String(localized: "M1K3 is answering…")
        case .ready: String(localized: "Answer ready")
        case .paused: String(localized: "Paused — open M1K3")
        }
    }

    /// The line under it.
    var detail: String {
        switch phase {
        case .thinking, .reading, .answering: String(localized: "Tap to open the chat.")
        case .ready: String(localized: "Tap to read it.")
        case .paused: String(localized: "Answers made on this phone pause when you leave M1K3.")
        }
    }

    /// The compact Dynamic Island's trailing word: short, so it never crowds the camera cut-out.
    var short: String {
        switch phase {
        case .thinking: String(localized: "Thinking")
        case .reading: String(localized: "Reading")
        case .answering: String(localized: "Answering")
        case .ready: String(localized: "Ready")
        case .paused: String(localized: "Paused")
        }
    }

    var symbol: String {
        switch phase {
        case .thinking: "ellipsis.bubble"
        case .reading: "doc.text"
        case .answering: "text.bubble"
        case .ready: "checkmark.circle.fill"
        case .paused: "pause.circle"
        }
    }

    /// Working phases wear the accent colour, settled ones (done, waiting) are white.
    var isWorking: Bool {
        switch phase {
        case .thinking, .reading, .answering: true
        case .ready, .paused: false
        }
    }
}
