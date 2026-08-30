//
//  OKFExport.swift
//  M1K3Memory
//
//  The OKF export serializer — ADR 0003's whole footprint: "your data, and
//  you can prove it never left" gains its corollary, "and you can take it
//  with you." Each LIVE memory becomes one markdown file with YAML
//  frontmatter (`type`, `title`, `timestamp`, `source` — OKF v0.1's shape,
//  GoogleCloudPlatform/knowledge-catalog), and each edge becomes a markdown
//  link with the relation riding in the link text.
//
//  Containment is the condition of adoption: this file is a serializer at
//  the boundary. Nothing in MemoryStore, retrieval, or the graph references
//  it; if the format dies, deletion costs this file and one menu item. It
//  is NEVER a storage format for memories at rest — a directory of
//  plaintext memories is exactly the artefact M1K3 exists not to produce,
//  which is why the app glue's save panel is a consent moment.
//
//  Signed: Kev + claude-fable-5, 2026-08-30, Confidence 0.9 (pure function,
//  pinned red-first; the save-panel glue is app-side, verify-at-⌘R).
//  Prior: none (new file). See docs/adr/0003.
//

import Foundation

public enum OKFExport {
    /// One file of the export: a name relative to the chosen folder, and its
    /// full content. The serializer never touches the filesystem.
    public struct File: Equatable, Sendable {
        public let name: String
        public let content: String

        public init(name: String, content: String) {
            self.name = name
            self.content = content
        }
    }

    /// Serialize the live graph. Superseded memories stay home — the export
    /// mirrors what recall would use, not the correction history. Output is
    /// deterministic and name-sorted so re-exports diff cleanly.
    public static func files(memories: [Memory], edges: [MemoryEdge], exportedAt: Date) -> [File] {
        let live = memories.filter { $0.supersededBy == nil }
        let names = Dictionary(uniqueKeysWithValues: live.map { ($0.id, fileName(for: $0)) })
        var files = live.map { memory in
            File(name: names[memory.id] ?? "\(memory.id.uuidString.lowercased()).md",
                 content: content(for: memory, edges: edges, names: names))
        }
        files.append(File(name: "README.md", content: readme(exportedAt: exportedAt, count: live.count)))
        return files.sorted { $0.name < $1.name }
    }

    // MARK: - Pieces

    /// Slug from the title (or the text for untitled facts) + a stable short
    /// id, so names are human-readable AND collision-free.
    static func fileName(for memory: Memory) -> String {
        let base = memory.title ?? memory.text
        let slug = base.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { partial, character in
                if character == "-", partial.hasSuffix("-") { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(48)
        let shortID = memory.id.uuidString.prefix(8).lowercased()
        let trimmed = String(slug).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "\(shortID).md" : "\(trimmed)-\(shortID).md"
    }

    private static func content(
        for memory: Memory, edges: [MemoryEdge], names: [UUID: String]
    ) -> String {
        var lines = ["---", "type: \(memory.kind.rawValue)"]
        if let title = memory.title {
            lines.append("title: \(quoted(title))")
        }
        lines.append("timestamp: \(iso8601(memory.createdAt))")
        lines.append("source: \(quoted(memory.source))")
        lines.append("---")
        lines.append("")
        lines.append(memory.text)
        // Outbound edges only, and only to memories that made the export —
        // a link to a superseded or missing fact would be a broken promise.
        let relations = edges
            .filter { $0.fromID == memory.id }
            .compactMap { edge in names[edge.toID].map { "- [\(edge.relation)](./\($0))" } }
            .sorted()
        if !relations.isEmpty {
            lines.append("")
            lines.append("## Relations")
            lines.append(contentsOf: relations)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func readme(exportedAt: Date, count: Int) -> String {
        let noun = count == 1 ? "memory" : "memories"
        return """
        # M1K3 memory export

        \(count) \(noun), exported from M1K3 on \(iso8601(exportedAt)).

        Each file is one remembered fact in Open Knowledge Format shape —
        markdown with YAML frontmatter; links between files are the memory
        graph's edges. Inside M1K3 these live encrypted; this folder is
        plain text and yours to guard.
        """ + "\n"
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
