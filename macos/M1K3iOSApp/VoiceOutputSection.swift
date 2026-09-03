//
//  VoiceOutputSection.swift
//  M1K3iOS / M1K3visionOS
//
//  The Voice section of Settings — how M1K3 sounds. Two tiers, same rows as the
//  Brain picker: Built-in (instant, no download — the default) and M1K3 Voice
//  (Kokoro, one ~354 MB download, then offline forever). Picking M1K3 Voice IS the
//  download consent; the bar below the rows is the honest progress; "Hear a
//  sample" speaks in whichever voice is live right now.
//
//  On the Simulator only Built-in is offered — M1K3 Voice is MLX, which aborts
//  there (AppCore.neuralVoiceAvailable).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-03, Confidence 0.8 (composition over
//  AppCore+VoiceOutput; the rows are the Brain picker's idiom byte-for-byte; the
//  download bar and the sample are verify-by-launch on device).
//  Prior: none (new file, patterned on SettingsScreen's Brain section).
//

import M1K3Inference
import M1K3Voice
import SwiftUI

struct VoiceOutputSection: View {
    @Environment(AppCore.self) private var core

    private var tiers: [VoiceTier] {
        AppCore.neuralVoiceAvailable ? VoiceTier.allCases : [.builtin]
    }

    var body: some View {
        Section {
            ForEach(tiers) { tier in
                Button {
                    core.selectVoiceTier(tier)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: tier.glyph)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tier.displayName).foregroundStyle(.primary)
                            Text(tier.tagline)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if core.selectedVoiceTier == tier {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            loadState
            if !AppCore.neuralVoiceAvailable {
                Text("M1K3 Voice runs on a real device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Hear a sample") {
                Task { await core.speakSample() }
            }
        } header: {
            Text("Voice")
        } footer: {
            // The chosen tier's own card copy — the fact and the guarantee.
            Text(core.selectedVoiceTier.detail)
        }
    }

    /// Download progress while M1K3 Voice stages, the failure if it didn't —
    /// the Mac's voiceOutputControl, in Form rows.
    @ViewBuilder
    private var loadState: some View {
        switch core.voiceLoad {
        case let .downloading(fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text(core.voiceLoad.label(modelName: "M1K3 Voice"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .preparing:
            ProgressView()
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle, .ready:
            EmptyView()
        }
    }
}
