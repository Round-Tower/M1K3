//
//  SettingsChoiceRow.swift
//  M1K3iOS
//
//  One pickable Settings row: a glyph, a title, a quiet line under it and a checkmark when chosen. The Brain
//  section (each tier, Home, Private Cloud) and the Voice section draw it.
//
//  The point of the type is the hit area. A `.plain` button in a Form takes touches only where it draws, so
//  the Spacer between the copy and the checkmark was dead and a row answered only on its words (Kev,
//  2026-11-17, on the 17 Pro). `.contentShape(.rect)` makes the whole row the target, and one type means a
//  new row can't drop it again.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-17, Confidence 0.85 (the dead Spacer is SwiftUI's documented
//  plain-style hit-testing; the fix is tried on the phone before the PR).
//  Prior: Unknown (the four rows it replaces were copies in SettingsScreen and VoiceOutputSection).
//

import SwiftUI

struct SettingsChoiceRow: View {
    /// An SF Symbol NAME, not an emoji.
    let glyph: String
    let title: String
    let detail: String
    let isChosen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: glyph)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.readableSecondary)
                }
                Spacer()
                if isChosen {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
