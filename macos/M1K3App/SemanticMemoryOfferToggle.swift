//
//  SemanticMemoryOfferToggle.swift
//  M1K3App
//
//  The pre-ticked "Also get semantic memory (1.3 GB): better recall of your notes" checkbox that rides
//  beside a Lil/Big download (BrainPickerView, the brain-upgrade card). Whether to show it is
//  `SemanticMemoryOffer.shouldOffer` via `AppEnvironment.offersSemanticMemory(alongside:)`; the caller
//  owns the `isOn` state (seeded from `SemanticMemoryOffer.preTicked`) and starts `.semanticMemory`
//  through `env.requestSemanticMemory(after:)` (the queue) when its brain's own button is tapped. Static: nothing here ticks.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.75 (thin view over a tested decision; the
//  look in the picker and the glass upgrade card is verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — O2 the detail line says when it starts ("Starts after Lil
//  is ready."); O4 a fixed-height slot, reserved (invisible, untappable) until the first disk scan lands. Confidence 0.75.

import M1K3Inference
import SwiftUI

struct SemanticMemoryOfferToggle: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var isOn: Bool
    /// What the layout does: nothing, a reserved invisible slot (before the first disk scan), or the toggle.
    let slot: SemanticMemoryOffer.Slot
    /// The brain this rides with, for "Starts after Lil is ready."
    let brainName: String

    /// Fixed: title, and a detail line that may wrap to two. The reserved slot and the shown toggle are the
    /// same height, so the offer appearing after the first scan never shoves the button beneath it (O4).
    static let slotHeight: CGFloat = 44

    var body: some View {
        if slot != .none {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(SemanticMemoryOffer.toggleTitle(size: env.semanticMemorySizeLabel))
                        .font(.callout)
                    Text(SemanticMemoryOffer.toggleDetail(brainName: brainName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .toggleStyle(.checkbox)
            .onChange(of: isOn) { _, _ in env.soundEffects.play(.selectionTick) }
            .frame(maxWidth: .infinity, minHeight: Self.slotHeight, maxHeight: Self.slotHeight, alignment: .leading)
            .opacity(slot == .shown ? 1 : 0)
            .allowsHitTesting(slot == .shown)
            .accessibilityHidden(slot != .shown)
        }
    }
}
