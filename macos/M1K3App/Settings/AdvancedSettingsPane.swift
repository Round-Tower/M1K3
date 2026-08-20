//
//  AdvancedSettingsPane.swift
//  M1K3App
//
//  The "Advanced" Settings tab: embeddings backend, voice input (WhisperKit),
//  call transcription, the generation-stats testing aid, the Agent
//  Interaction Log, index status, diagnostics, and licenses. Split out of the
//  old single-Form SettingsView (2026-07-13) — see SettingsView.swift for the
//  shell. The index-status readout is retitled "Status" (was "Memory") to
//  kill the duplicate-Memory-name problem now that the Memories consent
//  section lives on the You tab.
//
//  Signed: Kev + claude-fable-5, 2026-07-13, Confidence 0.85 (a straight move
//  — every footer/copy verbatim except the Status retitle). Prior: Kev +
//  claude-opus-4-8 (SettingsView.swift lineage, 2026-06-06).
//  Review: Kev + claude-opus-4-8, 2026-07-21 — added the "Import weights"
//  section: the UI entry point for WeightImport (M1K3MLX, shipped this
//  session with no caller until now). All the deciding lives in
//  WeightImportDisplay (M1K3MLX, TDD'd); this view is a thin switch over its
//  Outcome plus the NSOpenPanel/Task glue. Confidence 0.85 (compiles + app
//  builds; the render is verify-by-launch like every SwiftUI change in this
//  file family — see WeightImportDisplay.swift for what's actually pinned).
//

import AppKit
import M1K3Inference
import M1K3MLX
import M1K3WhisperKit
import SwiftUI

struct AdvancedSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(AppEnvironment.showGenerationStatsKey) private var showGenerationStats = false
    @AppStorage(AppEnvironment.conversationLogEnabledKey) private var conversationLogEnabled = false
    @AppStorage(AppEnvironment.includeMetricDigestsInIssueKey) private var includeMetricDigests = false
    @State private var showLicenses = false
    @State private var issueReported = false
    @State private var issueTruncated = false
    @State private var whatHappened = ""
    /// Which brain a folder import targets. Defaults to the first tier that
    /// actually has weights to import (Mini never appears — see
    /// `WeightImportDisplay.importableTiers`).
    @State private var weightImportTier: BrainTier = WeightImportDisplay.importableTiers().first ?? .lil

    var body: some View {
        Form {
            Section {
                LabeledContent("Mode",
                               value: env.usingMLXEmbeddings ? "MLX Qwen3-Embedding (semantic)" : "Hashing (offline)")
                if env.isReindexing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(env.embeddingStatus ?? "Rebuilding index…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    let embeddingToggleTitle = env.usingMLXEmbeddings
                        ? "Switch to Hashing (rebuild index)"
                        : "Switch to MLX semantic embeddings (rebuild index)"
                    Button(embeddingToggleTitle) {
                        Task { await env.switchEmbeddings(toMLX: !env.usingMLXEmbeddings) }
                    }
                    .buttonStyle(.glass)
                    if let status = env.embeddingStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Embeddings")
            } footer: {
                Text("Semantic MLX embeddings improve retrieval but download a model on "
                    + "first use and re-embed every stored chunk.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
            } header: {
                Text("Voice input")
            } footer: {
                Text("Tap the mic in the chat bar to dictate — tap again to send. Apple Speech "
                    + "works out of the box; WhisperKit is higher accuracy after a one-time "
                    + "model download (Small is the default). Changing the accuracy tier "
                    + "applies on the next launch. On-device only.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if env.isTranscribingCall {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Transcribing call…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if env.isPreparingBatchTranscription {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(env.lastCallStatus ?? "Preparing call transcription…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if env.batchTranscriptionReady {
                    LabeledContent("Transcription", value: "Ready")
                } else {
                    Button("Enable call transcription (downloads model)") {
                        Task { await env.enableCallTranscription() }
                    }
                    .buttonStyle(.glass)
                }
                if let status = env.lastCallStatus, !env.isPreparingBatchTranscription {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Call recording")
            } footer: {
                Text("Record a call from the chat toolbar (consent-gated). With transcription "
                    + "enabled, a stopped recording is transcribed, summarised, encrypted, and "
                    + "indexed — on-device.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show generation stats", isOn: $showGenerationStats)
            } header: {
                Text("Generation stats")
            } footer: {
                Text("A testing aid: shows context tokens and tokens/sec under each answer "
                    + "from Lil or Big. Mini (Apple's on-device model) doesn't report "
                    + "generation metrics.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            conversationLogSection

            Section("Status") {
                LabeledContent("Indexed items", value: "\(env.indexedItemCount)")
                    .monospacedDigit()
                LabeledContent("Model availability",
                               value: env.providerAvailable ? "Ready" : "Unavailable")
            }

            weightImportSection

            Section {
                Toggle("Include on-device crash/hang summaries", isOn: $includeMetricDigests)
                TextField("What happened? (optional)", text: $whatHappened, axis: .vertical)
                    .lineLimit(2 ... 5)
                    .textFieldStyle(.roundedBorder)
                Button("Report an issue…") {
                    Task {
                        issueTruncated = await IssueReporter.reportIssue(
                            whatHappened: whatHappened,
                            activeBrain: env.selectedBrain.displayName,
                            userProfile: M1K3Persona.userProfile,
                            metricDigests: includeMetricDigests ? env.recentMetricDigestLines() : []
                        )
                        issueReported = true
                    }
                }
                .buttonStyle(.glass)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(issueReported
                    ? (issueTruncated
                        ? "Full report copied to your clipboard — paste it into the issue body on GitHub."
                        : "Opened a prefilled issue on GitHub (also copied to your clipboard). Review before you submit.")
                    : "Copies recent logs + this Mac's details, scrubbed of paths, emails and "
                    + "your name, then opens a prefilled GitHub issue. MetricKit summaries "
                    + "(crash/hang kind, date, version — never raw data) are opt-in above. "
                    + "Nothing is sent until you submit.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Third-party licenses") { showLicenses = true }
                    .buttonStyle(.glass)
            } footer: {
                Text("M1K3 is built with open-source components. "
                    + "Everything runs on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showLicenses) {
            LicensesView()
        }
    }

    /// The Agent Interaction Log opt-in: full MCP request+response text is
    /// captured only while this is on (default OFF).
    private var conversationLogSection: some View {
        Section {
            Toggle("Log agent conversations", isOn: $conversationLogEnabled)
            Button("Clear log", role: .destructive) {
                try? env.conversationLog?.clear()
            }
            .buttonStyle(.glass)
        } header: {
            Text("Agent conversation log")
        } footer: {
            Text("On-device only, off by default. When on, M1K3 keeps the last "
                + "500 tool calls a connected agent makes — including which agent "
                + "called (its self-reported name). See them in Window → Agent Log, "
                + "or folded into the Heartbeat timeline.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "I already have these weights" — verify a folder against M1K3's
    /// pinned digests and install it so the app never re-downloads. The
    /// picker only ever offers tiers with something to import
    /// (`WeightImportDisplay.importableTiers` — Mini is Apple Foundation
    /// Models and never appears). The actual run is off the main actor
    /// (`AppEnvironment.importWeights` — it hashes gigabytes); this section
    /// just disables itself while `.importing` and switches on the result.
    private var weightImportSection: some View {
        Section {
            Picker("Brain", selection: $weightImportTier) {
                ForEach(WeightImportDisplay.importableTiers()) { tier in
                    Text(tier.displayName).tag(tier)
                }
            }
            .accessibilityLabel("Which brain's weights to import")
            .disabled(env.weightImportState == .importing)

            currentWeightsRow

            Button("Import weights from a folder…", action: presentWeightImportPanel)
                .buttonStyle(.glass)
                .disabled(env.weightImportState == .importing)
                .accessibilityLabel("Import \(weightImportTier.displayName) weights from a folder")

            weightImportStatusRow
        } header: {
            Text("Import weights")
        } footer: {
            Text("Already have a model's weights on disk from somewhere else? Point M1K3 at "
                + "the folder — it verifies every file against the digests pinned in this "
                + "build before installing, and refuses anything that doesn't match.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Where the selected brain's weights currently live — the natural
    /// companion to importing. When they're on disk, show the folder and a
    /// Reveal button; when they're not, say so plainly rather than point at an
    /// empty directory. Location comes from `WeightImport.defaultDestination`
    /// (download-base-aware, so the embedder resolves correctly too), install
    /// state from `env.isBrainDownloaded`.
    @ViewBuilder
    private var currentWeightsRow: some View {
        let modelID = weightImportTier.mlxModelID
        let location = modelID.map { WeightImport.defaultDestination(for: $0) }
        let status = WeightImportDisplay.folderStatus(
            isInstalled: env.isBrainDownloaded(weightImportTier),
            location: location
        )
        switch status {
        case let .present(url):
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("On this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(url.path(percentEncoded: false))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
                .accessibilityLabel("Reveal \(weightImportTier.displayName)'s weights in Finder")
            }
        case .absent:
            Text("Not on this Mac yet — download it, or import a folder below.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var weightImportStatusRow: some View {
        switch env.weightImportState {
        case .idle:
            EmptyView()
        case .importing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying and installing…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case let .result(.success(message)):
            Label(message, systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.caption)
                .foregroundStyle(.green)
        case let .result(.failure(message)):
            // Verbatim from WeightImportDisplay — these strings (the tamper
            // one especially) were worded deliberately; not truncated, not
            // softened.
            Label(message, systemImage: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// Directory-only NSOpenPanel (not `.fileImporter`: this needs
    /// `canChooseDirectories`/`canChooseFiles` precision that SwiftUI's
    /// modifier doesn't cleanly expose). Modal on the button's own click —
    /// no separate `isPresented` state to track.
    private func presentWeightImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose the folder holding \(weightImportTier.displayName)'s weights."
        // Start where this brain's weights would live, so a person importing
        // from a copy lands near the real thing rather than at their home dir.
        if let modelID = weightImportTier.mlxModelID {
            panel.directoryURL = WeightImport.defaultDestination(for: modelID).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await env.importWeights(from: url, for: weightImportTier) }
    }
}
