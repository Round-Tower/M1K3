//
//  MemoryExportCommands.swift
//  M1K3
//
//  ADR 0003's one menu item: File ▸ Export Memories… serializes the live
//  memory graph through OKFExport (M1K3Memory, pure + TDD'd) into a folder
//  the user chooses. The save panel IS the consent moment — an export is
//  plaintext by definition, outside every guarantee M1K3 makes once it
//  exists, and the panel says that in one plain sentence rather than a
//  disclosure triangle.
//
//  Signed: Kev + claude-fable-5, 2026-08-30, Confidence 0.8 (serializer is
//  package-pinned; the panel flow, the written folder, and the Finder
//  reveal are verify-at-⌘R). Prior: none (new file). See docs/adr/0003.
//

import AppKit
import M1K3LogCore
import M1K3Memory
import SwiftUI

struct MemoryExportCommands: Commands {
    let env: AppEnvironment?

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export Memories…") {
                MemoryExporter.run(store: env?.memoryStore)
            }
            .disabled(env?.memoryStore == nil)
        }
    }
}

@MainActor
enum MemoryExporter {
    // nonisolated: the detached export task logs its outcome off-main.
    private nonisolated static let log = M1K3Log.logger(.memoryGraph)

    /// Panel on the click (the AdvancedSettingsPane idiom — modal, no
    /// isPresented state), then store read + file writes off the main actor.
    static func run(store: MemoryStore?) {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Exports every remembered fact as plain-text Markdown. "
            + "Outside M1K3 this folder is not encrypted — it's yours to guard."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task.detached(priority: .utility) {
            let stamp = Date()
            let memories = (try? store.allMemories(includeSuperseded: false, limit: 100_000)) ?? []
            let edges = (try? store.allEdges(limit: 100_000)) ?? []
            let files = OKFExport.files(memories: memories, edges: edges, exportedAt: stamp)
            let folder = destination.appendingPathComponent(
                "M1K3 Memories \(stamp.formatted(.iso8601.year().month().day()))",
                isDirectory: true
            )
            var written = 0
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in files {
                    try file.content.write(
                        to: folder.appendingPathComponent(file.name), atomically: true, encoding: .utf8
                    )
                    written += 1
                }
            } catch {
                // Counts only — never memory content in the log.
                log.error("memory export failed after \(written, privacy: .public) files: \(error, privacy: .public)")
            }
            log.notice("memory export wrote \(written, privacy: .public) files")
            let revealTarget = folder
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([revealTarget])
            }
        }
    }
}
