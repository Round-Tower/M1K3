//
//  BrainAtHomeSection.swift
//  M1K3iOS / M1K3visionOS
//
//  The Settings section for Brain at Home, device side: pair (→ the
//  ceremony screen), the paired Mac's live status, and Forget. The privacy
//  line states the honest boundary: prompts go to YOUR Mac over your own
//  Wi-Fi, encrypted (TLS), and nowhere else.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.85. Prior: Unknown.
//
//  Review: Kev + claude-fable-5.1, 2026-09-03 — cognitive-load cut: both footers down to the fact + the guarantee.
//  Review: Kev + claude-fable-5.1, 2026-09-05 — the section appears only once paired; pairing lives on the Brain
//  section's Home row (one entry point). Confidence now 0.85.
//

import M1K3BrainLink
import SwiftUI

struct BrainAtHomeSection: View {
    @Environment(AppCore.self) private var core
    @State private var health: BrainHealth?
    @State private var checkedHealth = false
    @State private var confirmForget = false

    var body: some View {
        // Unpaired: the Brain section's Home row is the one way in (QA pass
        // 2026-09-05 — two "pair" entries on one screen was one too many).
        if let brain = core.homeBrain {
            paired(brain)
        }
    }

    private func paired(_ brain: PairedBrain) -> some View {
        Section {
            LabeledContent(brain.name) {
                statusLabel
            }
            .task(id: brain.identity) {
                health = await core.homeBrainHealth()
                checkedHealth = true
            }
            Button("Forget This Mac", role: .destructive) {
                confirmForget = true
            }
            .confirmationDialog(
                "Forget \(brain.name)? This device stops using its brain; also revoke this device on the Mac.",
                isPresented: $confirmForget,
                titleVisibility: .visible
            ) {
                Button("Forget", role: .destructive) {
                    core.forgetHomeBrain()
                }
            }
        } header: {
            Text("Brain at Home")
        } footer: {
            Text("Prompts go to your Mac over your own Wi‑Fi, encrypted — never to the internet.")
        }
    }

    @ViewBuilder private var statusLabel: some View {
        if let health {
            Label(
                health.ready ? "\(health.brain) ready" : "\(health.brain) warming",
                systemImage: "circle.fill"
            )
            .font(.caption)
            .foregroundStyle(health.ready ? .green : .orange)
        } else if checkedHealth {
            Label("Unreachable", systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}
