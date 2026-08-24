//
//  BrainAtHomeSection.swift
//  M1K3iOS / M1K3visionOS
//
//  The Settings section for Brain at Home, device side: pair (→ the
//  ceremony screen), the paired Mac's live status, and Forget. The privacy
//  line states the honest boundary: prompts go to YOUR Mac over your own
//  Wi-Fi, TLS-encrypted, and nowhere else.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.85. Prior: Unknown.
//

import M1K3BrainLink
import SwiftUI

struct BrainAtHomeSection: View {
    @Environment(AppCore.self) private var core
    @State private var health: BrainHealth?
    @State private var checkedHealth = false
    @State private var confirmForget = false

    var body: some View {
        Section {
            if let brain = core.homeBrain {
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
            } else {
                NavigationLink {
                    BrainPairingScreen()
                } label: {
                    Label("Pair with your Mac", systemImage: "qrcode.viewfinder")
                }
            }
        } header: {
            Text("Brain at Home")
        } footer: {
            Text(
                core.homeBrain == nil
                    ? "Use your Mac’s bigger brain from this device. Pair once by QR; "
                    + "everything stays on your own Wi-Fi."
                    : "When Home is selected, this device sends prompts to your Mac over "
                    + "your own Wi-Fi, TLS-encrypted — never to the internet. Your Mac "
                    + "answers with its bigger brain; its own turns come first."
            )
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
