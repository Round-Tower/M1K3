//
//  M1K3SettingsPane.swift
//  M1K3App
//
//  The "M1K3" Settings tab: which brain, how it thinks, the companion face,
//  and every voice setting — in and out. Split out of the old single-Form
//  SettingsView (2026-07-13) — see SettingsView.swift for the shell. Two
//  Kev-approved cuts landed here: "Prefer Apple on-device" is gone —
//  auto-route always prefers M1K3's own tuned model now (see
//  AppEnvironment+ChatHistory.swift's resolvedAutoRouteTier) — and "Ease off
//  when my Mac runs hot" is gone because Prudent Compute is ALWAYS ON now,
//  not opt-in (`applyCoolHead()`, was `applyCoolHeadIfEnabled()`) — the
//  footer below states that as fact, not as a toggle. "Show generation
//  stats" moved to the Advanced pane (a testing aid, not a brain setting).
//  Reasoning and Voice input (WhisperKit) moved IN from General/Advanced
//  (2026-09-01 IA pass) — everything about M1K3's mind and voice lives on
//  this one tab now, so "how do I fix dictation" or "how do I make it think
//  harder" is never a scavenger hunt across three tabs.
//
//  Signed: Kev + claude-fable-5, 2026-07-13, Confidence 0.85 (a straight move
//  of the Brain/Companion/Voice-output sections; the two cuts are honest
//  behaviour changes documented at their source, not dead UI). Prior: Kev +
//  claude-opus-4-8 (SettingsView.swift lineage, 2026-06-06).
//

import M1K3Chat
import M1K3Inference
import M1K3MLX
import M1K3Voice
import M1K3WhisperKit
import SwiftUI

struct M1K3SettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(AppEnvironment.autoRouteBrainKey) private var autoRouteBrain = false
    /// The retired folder awaiting the user's confirmation to delete.
    @State private var pendingRemoval: InstalledWeights?
    @AppStorage(AppEnvironment.thinkingModeKey) private var thinkingMode = ThinkingMode.auto.rawValue
    @AppStorage(AppEnvironment.voiceEchoCancellationKey) private var preferEchoCancellation = true

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
                retiredWeightsRows
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
                Mini is Apple's built-in model (instant). Lil and Big download once and \
                run entirely on this Mac. Auto-route picks the model that fits the \
                moment, and M1K3 eases off on its own when your Mac runs hot.
                """
                Text(copy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Reasoning", selection: $thinkingMode) {
                    Text("Auto").tag(ThinkingMode.auto.rawValue)
                    Text("Always think").tag(ThinkingMode.always.rawValue)
                    Text("Fast answers").tag(ThinkingMode.fast.rawValue)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Reasoning")
            } footer: {
                Text("Reasoning models think before answering — sharper on hard "
                    + "questions, slower on small talk. Auto decides per turn; voice "
                    + "mode has its own toggle and ignores this setting.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("Built-in is Apple's default voice. M1K3 Voice downloads a neural "
                    + "voice model and runs entirely offline. Character shapes the tone "
                    + "\u{2014} Clean is the full range, M1K3 is the signature sound, Radio "
                    + "leans lo-fi. Hit \u{201C}Hear a sample\u{201D} to compare.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            voiceInputSection

            HeartbeatSettingsSection(env: env)
        }
        .formStyle(.grouped)
        .onAppear { env.refreshRetiredWeights() }
        // Destructive, so hoisted off the leaf Button (see GeneralSettingsPane):
        // a confirmationDialog on a Button inside a Form can silently not show.
        .confirmationDialog(
            "Remove \(pendingRemoval?.repoID ?? "these weights")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let weights = pendingRemoval { env.removeRetiredWeights(weights) }
                pendingRemoval = nil
            }
        } message: {
            Text("Frees \((pendingRemoval?.bytes ?? 0).formatted(.byteCount(style: .file))) on this Mac. "
                + "Nothing uses these weights any more; picking that brain again would download them fresh.")
        }
        .scrollContentBackground(.hidden)
    }

    /// Shows the MLX Gemma weight download as a real progress bar while it
    /// streams (~1GB on first use), or the failure, so selecting MLX never looks
    /// like a silent hang. Renders nothing when idle or ready.
    /// One row per brain folder nothing claims (#222). Hidden when there is
    /// nothing to free — the common case.
    @ViewBuilder private var retiredWeightsRows: some View {
        if !env.retiredWeights.isEmpty {
            LabeledContent {
                Text(RetiredWeightsPolicy.totalBytes(env.retiredWeights).formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
            } label: {
                Label("Free up space", systemImage: "internaldrive")
                    .symbolRenderingMode(.hierarchical)
            }
            ForEach(env.retiredWeights) { weights in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(weights.repoID.split(separator: "/").last.map(String.init) ?? weights.repoID)
                            .font(.callout)
                        Text("No longer used · \(weights.bytes.formatted(.byteCount(style: .file)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove…") { pendingRemoval = weights }
                        .buttonStyle(.glass)
                }
            }
        }
    }

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

    /// Voice INPUT: recogniser choice + accuracy, and echo cancellation —
    /// merged into one section (moved in from Advanced/General, 2026-09-01)
    /// so every dictation question has one home, right under Voice output.
    private var voiceInputSection: some View {
        Section {
            LabeledContent("Active engine", value: env.activeTranscriberName)
            Picker("Accuracy", selection: Binding(
                get: { env.selectedWhisperModel },
                set: { env.selectWhisperModel($0) }
            )) {
                ForEach(WhisperModelVariant.allCases) { variant in
                    Text("\(variant.displayName) · \(variant.sizeHint)").tag(variant)
                }
            }
            whisperLoadRow
            Toggle("Keep other audio out of the mic", isOn: $preferEchoCancellation)
        } header: {
            Text("Voice input")
        } footer: {
            Text("Apple Speech works by default; WhisperKit is higher accuracy after "
                + "a one-time download and applies on the next launch. Echo "
                + "cancellation stops M1K3 hearing itself, at some cost to accuracy "
                + "in a quiet room.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var whisperLoadRow: some View {
        switch env.whisperLoad {
        case .idle, .failed:
            Button("Enable WhisperKit (downloads model)") {
                Task { await env.enableWhisperKit() }
            }
            .buttonStyle(.glass)
            if case let .failed(msg) = env.whisperLoad {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case let .downloading(fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text(env.whisperLoad.label(modelName: "WhisperKit"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .preparing:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView() // indeterminate — load has no honest fraction
                Text(env.whisperLoad.label(modelName: "WhisperKit"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label("WhisperKit ready", systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.callout)
                .foregroundStyle(.green)
        }
    }
}
