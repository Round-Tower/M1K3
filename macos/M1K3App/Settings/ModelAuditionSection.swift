//
//  ModelAuditionSection.swift
//  M1K3App
//
//  Settings > Advanced > Model auditions: import any MLX checkpoint folder
//  already on this Mac (a Hugging Face cache snapshot included) and stand it
//  in for Pocket, Lil or Big. The stock model comes back with one pick.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-29, Confidence 0.75 (verify-by-launch:
//  the open panel, the import and the live swap). Prior: Unknown
//
//  Review: Kev + claude-fable-5.1, 2026-09-29 — #452 review fold: Stock explains a launch
//  override (any pick, and remove), import refuses the live brain's folder, remove runs
//  async and never overlaps an import, PanelNamer is @MainActor. Confidence 0.75.
//

import AppKit
import M1K3Inference
import M1K3MLX
import SwiftUI

struct ModelAuditionSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var auditions: [AuditionModel] = []
    @State private var importing = false
    /// Import and remove never overlap: a remove's delete could eat a fresh copy of the same name.
    @State private var removing = false
    @State private var message: String?
    /// Bumped after a pick or a removal so the pickers re-read UserDefaults.
    @State private var revision = 0

    var body: some View {
        Section {
            ForEach(WeightImportDisplay.importableTiers()) { tier in
                Picker(tier.displayName, selection: binding(for: tier)) {
                    Text("Stock (\(tier.mlxModelID.map(Self.shortName) ?? "none"))").tag(String?.none)
                    ForEach(auditions) { model in
                        Text(model.repoID).tag(Optional(model.repoID))
                    }
                }
                .disabled(auditions.isEmpty)
            }
            ForEach(auditions) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.repoID).font(.callout)
                        Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { remove(model) }
                        .buttonStyle(.link)
                        .disabled(importing || removing)
                        .accessibilityLabel("Remove the \(model.repoID) audition")
                }
            }
            HStack(spacing: 8) {
                Button("Import a model folder…") { presentPanel() }
                    .buttonStyle(.glass)
                    .disabled(importing || removing)
                if importing {
                    ProgressView().controlSize(.small)
                    Text("Copying…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            SettingsHeader("Model auditions", systemImage: "theatermasks")
        } footer: {
            Text("Try any MLX model already on this Mac in a brain's place, then switch back. "
                + "Auditions aren't checked against M1K3's pinned digests, and the brain's own "
                + "model is never touched.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .id(revision)
        .task { await reload() }
    }

    private func binding(for tier: BrainTier) -> Binding<String?> {
        Binding(
            // A chosen id that isn't a complete audition (removed, or passed at launch
            // and never imported) reads as Stock, which is what actually serves.
            get: {
                let chosen = AuditionSelection.repoID(forTier: tier.rawValue)
                return auditions.contains { $0.repoID == chosen } ? chosen : nil
            },
            set: { choice in
                let name = choice.map(Self.shortName) ?? "its own model"
                switch env.setAudition(choice, for: tier) {
                case .setAtLaunch:
                    message = "\(tier.displayName) was given an audition when M1K3 was launched, "
                        + "so it keeps it until you relaunch without that option."
                case .applied: message = "\(tier.displayName) is now running \(name)."
                case .savedForLater: message = "\(tier.displayName) will run \(name) next time you switch to it."
                case .busy: message = "Finish the deep dive first, then pick again."
                }
                revision += 1
            }
        )
    }

    /// Off the main actor: listing sweeps staging and sizes every folder.
    private func reload() async {
        guard let store = AppEnvironment.auditionStore else { return }
        auditions = await Task.detached(priority: .utility) { store.list() }.value
    }

    private func remove(_ model: AuditionModel) {
        removing = true
        Task {
            do {
                switch try await env.removeAudition(model.repoID) {
                case .busy: message = "Finish the deep dive first, then remove it."
                case .setAtLaunch: message = "\(model.repoID) was chosen when M1K3 was launched. "
                    + "Relaunch without that option, then remove it."
                case .applied, .savedForLater: message = "Removed \(model.repoID)."
                }
            } catch {
                message = "Couldn't remove \(model.repoID): \(error.localizedDescription)"
            }
            removing = false
            await reload()
            revision += 1
        }
    }

    /// A folder picker that can see `~/.cache/huggingface` (hidden by default).
    private func presentPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Import"
        panel.message = "Choose a model folder: an MLX checkpoint, or a models--org--name folder "
            + "from the Hugging Face cache."
        // Not homeDirectoryForCurrentUser: in the sandbox that's the container.
        panel.directoryURL = Self.realHome.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        // The name it will be known by: prefilled from the folder the moment one is
        // picked, editable, because a plain folder's own name isn't its hub name.
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "org/model, e.g. mlx-community/LFM2.5-2.6B-4bit"
        nameField.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        let label = NSTextField(labelWithString: "Name:")
        let accessory = NSStackView(views: [label, nameField])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        let namer = PanelNamer(field: nameField)
        panel.delegate = namer // weak: kept alive across the modal run below
        let response = withExtendedLifetime(namer) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typed.isEmpty
            ? (AuditionStore.inferredRepoID(from: url) ?? url.lastPathComponent)
            : typed
        guard !env.isServingAudition(name) else {
            message = "\(name) is the brain running right now. Switch that brain to Stock, then import again."
            return
        }
        importing = true
        message = nil
        Task {
            do {
                let model = try await AppEnvironment.importAudition(from: url, as: name)
                message = "Imported \(model.repoID). Pick it for a brain above."
            } catch {
                message = error.localizedDescription
            }
            importing = false
            await reload()
        }
    }

    /// The user's real home folder, read from the password database: every Foundation
    /// home lookup answers with the app container inside the sandbox.
    static var realHome: URL {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            return URL(fileURLWithPath: "/Users", isDirectory: true)
        }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }

    static func shortName(_ repoID: String) -> String {
        repoID.split(separator: "/").last.map(String.init) ?? repoID
    }
}

/// Prefills the panel's name field from whichever folder is selected.
@MainActor
private final class PanelNamer: NSObject, NSOpenSavePanelDelegate {
    let field: NSTextField
    init(field: NSTextField) {
        self.field = field
    }

    func panelSelectionDidChange(_ sender: Any?) {
        guard let url = (sender as? NSOpenPanel)?.url else { return }
        field.stringValue = AuditionStore.inferredRepoID(from: url) ?? ""
    }
}
