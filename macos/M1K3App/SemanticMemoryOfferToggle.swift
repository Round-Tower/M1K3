//
//  SemanticMemoryOfferToggle.swift
//  M1K3App
//
//  The pre-ticked "Also get semantic memory (1.3 GB): better recall of your notes" checkbox that rides
//  beside a Lil/Big download (BrainPickerView, the brain-upgrade card). Whether to show it is
//  `SemanticMemoryOffer.shouldOffer` via `AppEnvironment.offersSemanticMemory(alongside:)`; the caller
//  owns the `isOn` state (seeded from `SemanticMemoryOffer.preTicked`) and starts `.semanticMemory`
//  through `env.startDownload` when its brain's own button is tapped. Static: nothing here ticks.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.75 (thin view over a tested decision; the
//  look in the picker and the glass upgrade card is verify-by-launch). Prior: none (new file).

import M1K3Inference
import SwiftUI

struct SemanticMemoryOfferToggle: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(SemanticMemoryOffer.toggleTitle(size: env.semanticMemorySizeLabel))
                    .font(.callout)
                Text(SemanticMemoryOffer.toggleDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .onChange(of: isOn) { _, _ in env.soundEffects.play(.selectionTick) }
    }
}
