//
//  OnboardingCards.swift
//  M1K3App
//
//  The selectable cards for the brain picker — Auto + Mini/Lil/Big — plus the
//  shared SelectionRadio vocabulary (CompanionSettings reuses it). VoiceCard and
//  SpeechVoiceCard were removed 2026-07-03 with the one-screen onboarding
//  collapse: their only consumers were the cut Ears/Voice wizard steps, and
//  Settings' Form-native controls cover both choices.
//
//  Signed: Kev + claude-sonnet-4-6, 2026-06-08, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-07-02, Confidence 0.9 — extracted the 4×
//  duplicated selection radio into SelectionRadio with a symbol-replace
//  transition; card titles moved to the shared Font.pixelTitle.
//  Review: Kev + claude-opus-4-6, 2026-10-12 — removed the "Recommended" badge: `isRecommended` property,
//  `recommendedBadge` view, and the HStack wrapping the title. The tier's policy role stays. Confidence 0.9.

import M1K3Inference
import SwiftUI

// MARK: - Selection radio

/// The shared card-selection radio. The checkmark draws in with a symbol
/// replace so picking a card reads as confirmation, not a hard pop.
struct SelectionRadio: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .font(.title3)
            .contentTransition(.symbolEffect(.replace))
            .animation(.default, value: isSelected)
            .accessibilityHidden(true)
    }
}

// MARK: - Brain card

struct BrainCard: View {
    let tier: BrainTier
    let isSelected: Bool
    /// True when this Mac is below the tier's memory floor — the card shows
    /// but can't be chosen (honest about why, no silent hiding).
    var isLocked = false
    /// True when the tier's weights are already on disk — the card says "ready"
    /// instead of dangling a download the user has already done.
    var isDownloaded = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: tier.glyph)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(tier.displayName).font(.pixelTitle)
                        .padding(.bottom, 2)
                    Text(tier.tagline)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tint)
                    Text(tier.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(sizeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
                SelectionRadio(isSelected: isSelected)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                isSelected ? .regular.tint(.accentColor.opacity(0.22)) : .regular,
                in: .rect(cornerRadius: 18)
            )
            .contentShape(.rect)
            .opacity(isLocked ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tier.displayName), \(tier.tagline). \(sizeLabel)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var sizeLabel: String {
        guard let megabytes = tier.approxDownloadMB else { return "Built-in · no download" }
        // Already fetched → say so, and don't imply another download is pending.
        if isDownloaded { return "On disk · ready" }
        var label = if megabytes >= 1000 {
            String(format: "~%.1f GB · one-time download", Double(megabytes) / 1000)
        } else {
            "~\(megabytes) MB · one-time download"
        }
        if isLocked, let floor = tier.minimumPhysicalMemoryGB {
            label += " · needs \(Int(floor))GB+ memory"
        }
        return label
    }
}

// MARK: - Auto ("Who cares") card

/// "Let M1K3 choose" — turns on auto-route (ADR 0001): M1K3 picks the brain for
/// this Mac and keeps adapting to power, memory and heat. Sits above the explicit
/// tiers as the no-decision default for people who'd rather not pick.
struct AutoBrainCard: View {
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "wand.and.stars")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Let M1K3 choose").font(.pixelTitle).padding(.bottom, 2)
                    Text("Recommended for most people")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tint)
                    Text("M1K3 picks the best brain for this Mac and keeps adapting to "
                        + "power, memory and heat. Change it any time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                SelectionRadio(isSelected: isSelected)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                isSelected ? .regular.tint(.accentColor.opacity(0.22)) : .regular,
                in: .rect(cornerRadius: 18)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Let M1K3 choose. Recommended for most people.")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
