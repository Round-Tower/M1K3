//
//  M1K3SettingsPane.swift
//  M1K3App
//
//  The "M1K3" Settings tab: which brain, the companion face, how it sounds.
//  Split out of the old single-Form SettingsView (2026-07-13) — see
//  SettingsView.swift for the shell. Two Kev-approved cuts landed here:
//  "Prefer Apple on-device" is gone — auto-route always prefers M1K3's own
//  tuned model now (see AppEnvironment+ChatHistory.swift's
//  resolvedAutoRouteTier) — and "Ease off when my Mac runs hot" is gone
//  because Prudent Compute is ALWAYS ON now, not opt-in (`applyCoolHead()`,
//  was `applyCoolHeadIfEnabled()`) — the footer below states that as fact,
//  not as a toggle. "Show generation stats" moved to the Advanced pane (a
//  testing aid, not a brain setting).
//
//  Signed: Kev + claude-fable-5, 2026-07-13, Confidence 0.85 (a straight move
//  of the Brain/Companion/Voice-output sections; the two cuts are honest
//  behaviour changes documented at their source, not dead UI). Prior: Kev +
//  claude-opus-4-8 (SettingsView.swift lineage, 2026-06-06).
//

import M1K3Inference
import M1K3Voice
import SwiftUI

struct M1K3SettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(AppEnvironment.autoRouteBrainKey) private var autoRouteBrain = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(env.selectedBrain.tagline).foregroundStyle(.secondary)
                } label: {
                    Label(env.selectedBrain.displayName, systemImage: env.selectedBrain.glyph)
                        .symbolRenderingMode(.hierarchical)
                }
                modelLoadRow
                brainUpgradeRow
                Button("Change brain…") {
                    // Brain-only re-pick: deep-link to the brain step and finish on
                    // wake, instead of replaying the empty "Who am I talking to?"
                    // screen (the old re-trigger bug). One home for the deep-link.
                    env.routeToOnboardingBrainPicker()
                }
                .buttonStyle(.glass)
                Toggle("Auto-route (M1K3 picks the brain)", isOn: $autoRouteBrain)
                    .onChange(of: autoRouteBrain) { _, _ in env.applyAutoRouteIfEnabled() }
            } header: {
                Text("Brain")
            } footer: {
                // A multiline literal (no `+` chain) keeps this copy out of the
                // ViewBuilder's overload resolution — the old 7-segment `String`
                // concatenation tripped "unable to type-check in reasonable time",
                // which then cascaded into phantom "cannot find … in scope" errors
                // elsewhere in the file. `\` joins wrapped lines; blank-free line
                // breaks become the paragraph `\n`s.
                let copy = """
                Mini is Apple's built-in model (instant). Lil and Big are local models \
                that download once. On-device only — nothing leaves this Mac.
                Auto-route lets M1K3 pick its own tuned model — always sized to what \
                this Mac runs comfortably.
                M1K3 automatically eases its effort when your Mac runs hot — it never \
                changes your brain.
                """
                Text(copy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            CompanionSettingsSection(env: env)

            Section {
                LabeledContent("Active voice", value: env.selectedVoiceTier.displayName)
                voiceOutputControl
                if env.selectedVoiceTier == .m1k3Voice {
                    // Character applies to the neural voice's effect chain, so it's
                    // only meaningful on that tier. Live: the next chunk carries it,
                    // which is what makes "Hear a sample" an A/B test.
                    Picker("Character", selection: Binding(
                        get: { env.voiceCharacter },
                        set: { env.setVoiceCharacter($0) }
                    )) {
                        ForEach(VoiceCharacter.allCases, id: \.rawValue) { character in
                            Text(character.displayName).tag(character)
                        }
                    }
                    Text(env.voiceCharacter.summary)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Hear a sample") { Task { await env.speakSample() } }
                    .buttonStyle(.glass)
            } header: {
                Text("Voice output")
            } footer: {
                Text("How M1K3 sounds when it speaks. Built-in is Apple's clear default; "
                    + "M1K3 Voice runs the speech through M1K3's own voice character and "
                    + "downloads the neural voice model for offline use. On-device only. "
                    + "Character shapes that voice \u{2014} Clean is the full neural range, "
                    + "M1K3 is the signature transmitted sound, Radio leans further into "
                    + "lo-fi. Switch and hit \u{201C}Hear a sample\u{201D} to compare.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HeartbeatSettingsSection(env: env)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Shows the MLX Gemma weight download as a real progress bar while it
    /// streams (~1GB on first use), or the failure, so selecting MLX never looks
    /// like a silent hang. Renders nothing when idle or ready.
    @ViewBuilder private var modelLoadRow: some View {
        switch env.modelLoad {
        case let .downloading(fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .controlSize(.small)
                    .frame(maxWidth: 160)
                Text(env.modelLoad.label(modelName: env.downloadingBrainName))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small) // indeterminate
                Text(env.modelLoad.label(modelName: env.downloadingBrainName))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failed:
            Label(env.modelLoad.label(modelName: env.downloadingBrainName), systemImage: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
                .font(.caption).foregroundStyle(.orange)
        case .idle, .ready:
            EmptyView()
        }
    }

    /// The ladder rung the background upgrade currently targets, for row copy.
    private var upgradeTargetName: String {
        env.brainUpgradeTarget?.displayName ?? "brain"
    }

    /// The background upgrade's quiet home: live % while the target fetches
    /// invisibly, the failure reason when it gave up (the chat stays silent
    /// about both — this row is where "what's it doing?" gets an answer).
    @ViewBuilder private var brainUpgradeRow: some View {
        switch env.brainUpgrade {
        case let .fetching(fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .controlSize(.small)
                    .frame(maxWidth: 160)
                Text("Fetching \(upgradeTargetName) in the background… \(Int((fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case let .failed(_, transient):
            Label(
                transient
                    ? "Background \(upgradeTargetName) fetch paused — will retry."
                    : "Background \(upgradeTargetName) fetch failed. Use “Change brain…” to download directly.",
                systemImage: "exclamationmark.triangle"
            )
            .symbolRenderingMode(.hierarchical)
            .font(.caption).foregroundStyle(.orange)
        case .idle, .offered, .staged, .done, .dismissed:
            EmptyView()
        }
    }

    /// The voice-output tier control: progress while the M1K3 Voice model
    /// downloads, otherwise a Built-in ↔ M1K3 Voice toggle (+ any failure).
    @ViewBuilder
    private var voiceOutputControl: some View {
        switch env.voiceLoad {
        case let .downloading(fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text(env.voiceLoad.label(modelName: "M1K3 Voice"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        default:
            if env.selectedVoiceTier == .m1k3Voice {
                Button("Switch to Built-in voice") { env.selectVoiceTier(.builtin) }
                    .buttonStyle(.glass)
            } else {
                Button("Upgrade to M1K3 Voice (downloads model)") { env.selectVoiceTier(.m1k3Voice) }
                    .buttonStyle(.glass)
            }
            if case let .failed(message) = env.voiceLoad {
                Label(message, systemImage: "exclamationmark.triangle")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
