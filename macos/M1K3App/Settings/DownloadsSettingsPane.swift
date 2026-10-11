//
//  DownloadsSettingsPane.swift
//  M1K3App
//
//  Settings > Brains & downloads (Kev, 2026-10-11: "downloading M1K3's brains, embedder,
//  WhisperKit all need easy UX"): one row per thing M1K3 can download — name, what it is for,
//  its size, where it stands, and the buttons that state allows. The rows come from the pure
//  `DownloadCatalogue` (AppEnvironment+Downloads feeds it); this file only draws them.
//  "Free up space" (brain folders nothing claims any more) lives here too, as its own section.
//  Removing anything asks first.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.7 (a thin view over tested parts;
//  layout and the buttons are verify-by-launch). Prior: none (new file; the retired-folder rows
//  and their dialog moved here from M1K3SettingsPane.swift, signed there).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — B5 refreshes on TRANSITIONS only (a load or
//  fetch starting or settling), never per progress tick; B6 Semantic memory confirms (it re-indexes your notes) and
//  disables while an answer streams; new rows for partial, removing, checking and re-indexing states.
//  Confidence 0.7 (verify-by-launch).

import M1K3Inference
import M1K3MLX
import SwiftUI

struct DownloadsSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    /// The row awaiting the user's confirmation to delete.
    @State private var pendingRemoval: DownloadItem?
    /// The retired brain folder awaiting the same.
    @State private var pendingRetired: InstalledWeights?
    /// Semantic memory's Download is a switch plus a re-index of the notes: confirm first (B6).
    @State private var pendingSemantic = false

    var body: some View {
        let items = env.downloadItems
        Form {
            Section {
                ForEach(items.filter { $0.kind.brainTier != nil }) { row($0) }
            } header: {
                SettingsHeader("Brains", systemImage: "brain")
            }
            Section {
                ForEach(items.filter { $0.kind.brainTier == nil }) { row($0) }
            } header: {
                SettingsHeader("Memory, ears & voice", systemImage: "ear")
            } footer: {
                Text("Downloads come from huggingface.co (and github.com for the voice pack), once, and "
                    + "then run on this Mac. Nothing is removed without asking.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            retiredSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Appear reads the disk, Apple Intelligence and the retired folders once; after that the
        // disk is re-read only when something STARTS or SETTLES (`isActive` flips), never on a
        // progress tick (B5). The bars themselves read the load states directly, not the scan.
        .onAppear { env.refreshDownloads(onAppear: true) }
        .onChange(of: env.modelLoad.isActive) { _, _ in env.refreshDownloads() }
        .onChange(of: env.voiceLoad.isActive) { _, _ in env.refreshDownloads() }
        .onChange(of: env.whisperLoad.isActive) { _, _ in env.refreshDownloads() }
        .onChange(of: env.usingMLXEmbeddings) { _, _ in env.refreshDownloads() }
        .onChange(of: env.isReindexing) { _, _ in env.refreshDownloads() }
        .onChange(of: isUpgradeFetching) { _, _ in env.refreshDownloads() }
        // Destructive, so hoisted off the leaf Button (see GeneralSettingsPane): a
        // confirmationDialog on a Button inside a Form can silently not show.
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "this download")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = pendingRemoval { env.removeDownload(item.kind) }
                pendingRemoval = nil
            }
        } message: {
            Text("Frees \(sizeLabel(pendingRemoval)) on this Mac. Nothing is using it right now; "
                + "you can download it again any time.")
        }
        .confirmationDialog(
            "Turn on Semantic memory?", isPresented: $pendingSemantic, titleVisibility: .visible
        ) {
            Button("Download and re-index") { env.startDownload(.semanticMemory) }
        } message: {
            Text("This downloads the embedder, then re-indexes your notes so they can be found by meaning. "
                + "It can take a few minutes, and I can't answer until it's done.")
        }
        .confirmationDialog(
            "Remove \(pendingRetired?.repoID ?? "these weights")?",
            isPresented: Binding(get: { pendingRetired != nil }, set: { if !$0 { pendingRetired = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let weights = pendingRetired { env.removeRetiredWeights(weights) }
                pendingRetired = nil
            }
        } message: {
            Text("Frees \((pendingRetired?.bytes ?? 0).formatted(.byteCount(style: .file))) on this Mac. "
                + "Nothing uses these weights any more; picking that brain again would download them fresh.")
        }
    }

    /// Whether the background brain upgrade is fetching: the one `brainUpgrade` fact that moves disk.
    private var isUpgradeFetching: Bool {
        if case .fetching = env.brainUpgrade { true } else { false }
    }

    // MARK: - Rows

    private func row(_ item: DownloadItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name).font(.headline)
                    Text(sizeLabel(item)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(item.purpose).font(.callout).foregroundStyle(.secondary)
                status(of: item)
            }
            Spacer(minLength: 8)
            buttons(for: item)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func sizeLabel(_ item: DownloadItem?) -> String {
        guard let item else { return "" }
        return (item.sizeIsApproximate ? "~" : "") + item.bytes.formatted(.byteCount(style: .file))
    }

    @ViewBuilder
    private func status(of item: DownloadItem) -> some View {
        switch item.state {
        case .absent:
            EmptyView()
        case let .downloading(fraction):
            VStack(alignment: .leading, spacing: 3) {
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 220)
                        .accessibilityLabel("\(item.name) download")
                        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                    Text("Downloading… \(Int((fraction * 100).rounded()))%")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.callout).foregroundStyle(.secondary)
                }
                if !item.actions.contains(.cancel) {
                    Text("This one can't be stopped once it starts.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        case .preparing:
            spinner("Getting ready…")
        case .reindexing:
            spinner("Re-indexing your notes…")
        case .removing:
            spinner("Removing…")
        case .checking:
            spinner("Checking…")
        case .partial:
            Label("Partly downloaded", systemImage: "arrow.down.circle.dotted")
                .symbolRenderingMode(.hierarchical)
                .font(.callout).foregroundStyle(.secondary)
        case .ready:
            Label("Downloaded", systemImage: "checkmark.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.callout).foregroundStyle(.secondary)
        case .inUse:
            Label("In use", systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.callout).foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
                .font(.callout).foregroundStyle(.orange)
        }
    }

    private func spinner(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func downloadVerb(for item: DownloadItem) -> String {
        switch item.state {
        case .absent: String(localized: "Download")
        case .partial: String(localized: "Resume")
        default: String(localized: "Try again")
        }
    }

    @ViewBuilder
    private func buttons(for item: DownloadItem) -> some View {
        if item.actions.contains(.download) {
            let verb = downloadVerb(for: item)
            Button(verb) {
                if item.kind == .semanticMemory { pendingSemantic = true } else { env.startDownload(item.kind) }
            }
            .buttonStyle(.glass)
            // Switching Semantic memory on re-indexes the notes, which an answer in flight would race.
            .disabled(item.kind == .semanticMemory && (env.chat.isResponding || env.isReindexing))
            .accessibilityLabel("\(verb) \(item.name)")
        }
        if item.actions.contains(.cancel) {
            Button("Cancel") { env.cancelDownload(item.kind) }
                .buttonStyle(.glass)
                .accessibilityLabel("Cancel \(item.name) download")
        }
        if item.actions.contains(.remove) {
            Button("Remove…") { pendingRemoval = item }
                .buttonStyle(.glass)
                .accessibilityLabel("Remove \(item.name)")
        }
    }

    // MARK: - Free up space

    /// One row per brain folder nothing claims (#222), the old "Free up space" list. Hidden when
    /// there is nothing to free, the common case.
    @ViewBuilder private var retiredSection: some View {
        if !env.retiredWeights.isEmpty {
            Section {
                if let failure = env.retiredWeightsFailure {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                }
                ForEach(env.retiredWeights) { weights in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(weights.repoID.split(separator: "/").last.map(String.init) ?? weights.repoID)
                                .font(.callout)
                            Text("No longer used · \(weights.bytes.formatted(.byteCount(style: .file)))")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove…") { pendingRetired = weights }
                            .buttonStyle(.glass)
                            .accessibilityLabel("Remove \(weights.repoID)")
                    }
                }
            } header: {
                HStack {
                    SettingsHeader("Free up space", systemImage: "internaldrive")
                    Spacer()
                    Text(RetiredWeightsPolicy.totalBytes(env.retiredWeights).formatted(.byteCount(style: .file)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}
