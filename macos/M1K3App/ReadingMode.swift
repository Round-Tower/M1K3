//
//  ReadingMode.swift
//  M1K3App
//
//  How M1K3's replies are typeset — a reading-accessibility choice. Dyslexia is
//  first-class here (Kev's own need): besides the system default and a serif, the
//  modes offer OpenDyslexic and a bionic-reading transform. Persisted app-wide via
//  @AppStorage(readingModeKey) and applied in MessageView.
//
//  Signed: Kev + claude-sonnet-4-6, 2026-06-08, Confidence 0.85, Prior: Unknown

//  Review: Kev + claude-fable-5.2, 2026-11-12 — `face` maps a mode onto
//  `ReadingTypography`'s table, where the sizes and spacing now live.
//  Review: claude-opus-5-5, 2026-11-19 — l10n phase 0: `displayName` and `detail` are LocalizedStringKey (they only
//  feed Text, on the Mac and in the iOS shell), so the catalog extracts them. English renders unchanged.

import M1K3AnswerBlocks
import SwiftUI

enum ReadingMode: String, CaseIterable, Identifiable {
    case standard
    case serif
    case dyslexia
    case bionic

    /// @AppStorage key — shared by MessageView and Settings.
    static let storageKey = "readingMode"

    var id: String {
        rawValue
    }

    var face: ReadingTypography.Face {
        switch self {
        case .standard: .standard
        case .serif: .serif
        case .dyslexia: .dyslexia
        case .bionic: .bionic
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .standard: "Default"
        case .serif: "Serif"
        case .dyslexia: "Dyslexia-friendly"
        case .bionic: "Bionic reader"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .standard: "The system font — clean and familiar."
        case .serif: "A serif face; some readers find the strokes easier to track."
        case .dyslexia: "OpenDyslexic — weighted letterforms + roomier spacing."
        case .bionic: "Bolds the start of each word to guide the eye."
        }
    }
}
