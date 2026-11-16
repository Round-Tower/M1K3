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
import SwiftUI

struct TurnActivityCopy {
    let phase: TurnActivityPhase

    /// The headline: also the VoiceOver label.
    var title: String {
        switch phase {
        case .thinking: String(localized: "M1K3 is thinking…")
        case .reading: String(localized: "M1K3 is reading…")
        case .answering: String(localized: "M1K3 is answering…")
        case .ready: String(localized: "Answer ready")
        case .paused: String(localized: "Paused — open M1K3 to finish")
        }
    }

    /// The line under it.
    var detail: String {
        switch phase {
        case .thinking, .reading, .answering: String(localized: "Tap to open the chat.")
        case .ready: String(localized: "Tap to read it.")
        case .paused: String(localized: "Leaving M1K3 stopped this answer.")
        }
    }

    /// The compact Dynamic Island's trailing word: short, so it never crowds the camera cut-out.
    var short: String {
        switch phase {
        // Silkscreen is wide (about 8 pt a letter at 12 pt): five letters at most.
        case .thinking: String(localized: "Think")
        case .reading: String(localized: "Read")
        case .answering: String(localized: "Reply")
        case .ready: String(localized: "Ready")
        case .paused: String(localized: "Pause")
        }
    }

    /// Working phases wear the phosphor green, settled ones (done, waiting) the near-white mark.
    var titleColor: Color {
        switch phase {
        case .thinking, .reading, .answering: TurnBrand.phosphor
        case .ready, .paused: TurnBrand.mark
        }
    }
}
