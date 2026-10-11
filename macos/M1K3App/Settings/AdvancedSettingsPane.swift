//
//  AdvancedSettingsPane.swift
//  M1K3App
//
//  The "Advanced" Settings tab: embeddings backend, call transcription, the
//  generation-stats testing aid, index status, diagnostics, and licenses. Split out of the old single-Form
//  SettingsView (2026-07-13) — see SettingsView.swift for the shell. The
//  index-status readout is retitled "Status" (was "Memory") to kill the
//  duplicate-Memory-name problem now that the Memories consent section lives
//  on the You tab. Voice input (WhisperKit) moved to the M1K3 tab (2026-09-01
//  IA pass) — it sits next to Voice output now, not stranded here.
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
//  Review: Kev + claude-opus-5-5, 2026-09-23 — the Settings-screen pass: section headers are
//  SettingsHeader (icon + readable title) and caption text is callout, for readability. Confidence 0.85.
//  Review: Kev + claude-fable-5.1, 2026-10-10 (one embedder: EmbeddingGemma 2) — the Mode value names EmbeddingGemma 2.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — 1.1 Settings restructure (Kev, TestFlight): Import weights and Model
//  auditions left Settings (the 2026-07-21 import section and the 2026-09-29 audition section are gone), and the
//  Agent conversation log moved to the MCP Server pane. Confidence 0.8 (verify-by-launch).
//

import M1K3Inference
import SwiftUI

struct AdvancedSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(AppEnvironment.showGenerationStatsKey) private var showGenerationStats = false
    @AppStorage(AppEnvironment.includeMetricDigestsInIssueKey) private var includeMetricDigests = false
    @State private var showLicenses = false
    @State private var issueReported = false
    @State private var issueTruncated = false
    @State private var whatHappened = ""
    var body: some View {
        Form {
            Section {
                LabeledContent("Mode",
                               value: env.usingMLXEmbeddings ? "MLX EmbeddingGemma 2 (semantic)" : "Hashing (offline)")
                if env.isReindexing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(env.embeddingStatus ?? "Rebuilding index…")
                            .font(.callout).foregroundStyle(.secondary)
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
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } header: {
                SettingsHeader("Embeddings", systemImage: "point.3.connected.trianglepath.dotted")
            } footer: {
                Text("Semantic MLX embeddings improve retrieval but download a model on "
                    + "first use and re-embed every stored chunk.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                if env.isTranscribingCall {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Transcribing call…").font(.callout).foregroundStyle(.secondary)
                    }
                } else if env.isPreparingBatchTranscription {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(env.lastCallStatus ?? "Preparing call transcription…")
                            .font(.callout).foregroundStyle(.secondary)
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
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                SettingsHeader("Call recording", systemImage: "phone.bubble")
            } footer: {
                Text("Record a call from the chat toolbar (consent-gated). With transcription "
                    + "enabled, a stopped recording is transcribed, summarised, encrypted, and "
                    + "indexed — on-device.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show generation stats", isOn: $showGenerationStats)
            } header: {
                SettingsHeader("Generation stats", systemImage: "gauge.with.dots.needle.33percent")
            } footer: {
                Text("A testing aid: shows context tokens and tokens/sec under each answer "
                    + "from Lil or Big. Mini (Apple's on-device model) doesn't report "
                    + "generation metrics.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Indexed items", value: "\(env.indexedItemCount)")
                    .monospacedDigit()
                LabeledContent("Model availability",
                               value: env.providerAvailable ? "Ready" : "Unavailable")
            } header: {
                SettingsHeader("Status", systemImage: "info.circle")
            }

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
                SettingsHeader("Diagnostics", systemImage: "stethoscope")
            } footer: {
                Text(issueReported
                    ? (issueTruncated
                        ? "Full report copied to your clipboard — paste it into the issue body on GitHub."
                        : "Opened a prefilled issue on GitHub (also copied to your clipboard). Review before you submit.")
                    : "Copies recent logs and this Mac's details, scrubbed of paths, "
                    + "emails and your name, into a prefilled GitHub issue — nothing "
                    + "sent until you submit. MetricKit summaries above are opt-in.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Button("Third-party licenses") { showLicenses = true }
                    .buttonStyle(.glass)
            } footer: {
                Text("M1K3 is built with open-source components. "
                    + "Everything runs on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showLicenses) {
            LicensesView()
        }
    }
}
