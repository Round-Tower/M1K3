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
//  Review: Kev + claude-opus-5.5, 2026-11-17 — `isStale`: a working card past its stale date says "Open M1K3 to
//  check" / "This card stopped updating." with the eyes-shut face. Words by feel; owed on a phone.
//  Review: claude-opus-5-5, 2026-11-19 — localisation Phase 0: the compact words carry a translator comment (five
//  letters at most). Bundle.main here is the extension's own bundle, so these resolve from
//  M1K3LiveActivityExtension/Localizable.xcstrings. English unchanged.
//  Review: Kev + claude-opus-5.5, 2026-11-26 — words for the voice phases behind the lock ("M1K3 is listening…",
//  "M1K3 is speaking…", Hear / Talk). English only until the next localisation wave. Confidence 0.75.

import M1K3LiveActivity
import SwiftUI

struct TurnActivityCopy {
    let phase: TurnActivityPhase
    /// The card's stale date has passed: the app stopped updating it (TurnActivityStaleness).
    var isStale = false

    /// A working card nobody can update any more: it says so instead of "thinking" forever.
    private var stopped: Bool {
        isStale && TurnActivityStaleness.isWorking(phase)
    }

    /// The face to draw (a stopped card shuts its eyes).
    var facePhase: TurnActivityPhase {
        TurnActivityStaleness.facePhase(phase, isStale: isStale)
    }

    /// The headline: also the VoiceOver label.
    var title: String {
        if stopped { return String(localized: "Open M1K3 to check") }
        return switch phase {
        case .thinking: String(localized: "M1K3 is thinking…")
        case .reading: String(localized: "M1K3 is reading…")
        case .answering: String(localized: "M1K3 is answering…")
        case .ready: String(localized: "Answer ready")
        case .paused: String(localized: "Paused — open M1K3 to finish")
        case .listening: String(localized: "M1K3 is listening…")
        case .speaking: String(localized: "M1K3 is speaking…")
        }
    }

    /// The line under it.
    var detail: String {
        if stopped { return String(localized: "This card stopped updating.") }
        return switch phase {
        case .thinking, .reading, .answering: String(localized: "Tap to open the chat.")
        case .ready: String(localized: "Tap to read it.")
        case .paused: String(localized: "Leaving M1K3 stopped this answer.")
        case .listening, .speaking: String(localized: "Voice mode is on. Tap to open.")
        }
    }

    /// The compact Dynamic Island's trailing word: short, so it never crowds the camera cut-out.
    var short: String {
        if stopped { return String(localized: "Open", comment: "Dynamic Island word in the wide pixel font: five letters at most") }
        return switch phase {
        // Silkscreen is wide (about 8 pt a letter at 12 pt): five letters at most.
        case .thinking: String(localized: "Think", comment: "Dynamic Island word in the wide pixel font: five letters at most")
        case .reading: String(localized: "Read", comment: "Dynamic Island word in the wide pixel font: five letters at most")
        case .answering: String(localized: "Reply", comment: "Dynamic Island word in the wide pixel font: five letters at most")
        case .ready: String(localized: "Ready", comment: "Dynamic Island word in the wide pixel font: five letters at most")
        case .paused: String(localized: "Pause", comment: "Dynamic Island word in the wide pixel font: five letters at most")
        case .listening: String(localized: "Hear", comment: "Dynamic Island word in the wide pixel font: five letters at most")
        case .speaking: String(localized: "Talk", comment: "Dynamic Island word in the wide pixel font: five letters at most")
        }
    }

    /// Working phases wear the phosphor green, settled ones (done, waiting) the near-white mark.
    var titleColor: Color {
        if stopped { return TurnBrand.mark }
        return switch phase {
        case .thinking, .reading, .answering, .listening, .speaking: TurnBrand.phosphor
        case .ready, .paused: TurnBrand.mark
        }
    }
}
