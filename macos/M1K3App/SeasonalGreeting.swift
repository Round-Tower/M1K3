//
//  SeasonalGreeting.swift
//  M1K3App (shared with M1K3iOS)
//
//  The one line M1K3 says in costume. Mounted by the Mac GreetingCard (returning-user
//  slot only, never the first-session hero) and the iOS chat hero while a
//  `SeasonalLook` is active. Copy only — the persona / system prompt is untouched
//  (prompt edits have measured security costs).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8 (copy is a first draft in
//  the villain-on-your-side voice; placement is verify-by-launch). Prior: Unknown.
//

import M1K3Avatar
import SwiftUI

enum SeasonalGreeting {
    /// One line, at most 70 characters, nil when no look is in season.
    static func line(for season: SeasonalLook?) -> String? {
        switch season {
        case .halloween:
            String(
                localized: "Happy Halloween! I carved the pumpkin; you bring the questions.",
                comment: "Seasonal greeting shown 24 Oct - 1 Nov. M1K3 is a theatrical villain who is entirely on the user's side; keep it playful and family-safe, one short line."
            )
        case nil:
            nil
        }
    }
}

/// The greeting line as a view (nothing when out of season).
struct SeasonalGreetingLine: View {
    let season: SeasonalLook?
    var font: Font = .title3

    var body: some View {
        if let text = SeasonalGreeting.line(for: season) {
            Text(text)
                .font(font)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
