//
//  OKFImportParser.swift
//  M1K3Import
//
//  Reads what `OKFExport` writes (#711, ADR 0003's deferred "ingest" — the bundle it waited for
//  now exists): one markdown file per memory, `---` frontmatter (`type`, `title`, `timestamp`,
//  `source`, values quoted with `\"` / `\\` escapes), the fact as the body, and an optional
//  trailing `## Relations` list of links. It takes FILES, never a path: the import UI reads the
//  folder the user chose, and M1K3Memory stays OKF-ignorant on the read side too (containment).
//
//  A file without frontmatter or a `type` (OKF's one required field) is skipped, not thrown; an
//  unknown `type` reads as a note, the distiller's own fallback.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (round trip pinned against the real
//  serializer).
//  Prior: none (new file).

import Foundation
import M1K3Chat
import M1K3Memory

public enum OKFImportParser {
    public static func parse(files: [OKFExport.File]) -> ImportBundle {
        ImportBundle(provider: .m1k3, facts: files.sorted { $0.name < $1.name }.compactMap(fact(from:)))
    }

    static func fact(from file: OKFExport.File) -> ImportedFact? {
        let name = file.name.lowercased()
        guard name.hasSuffix(".md"), !name.hasSuffix("readme.md"),
              let (front, body) = split(file.content.replacingOccurrences(of: "\r\n", with: "\n")),
              let type = ImportJSON.nonEmpty(front["type"]),
              let text = ImportJSON.nonEmpty(withoutRelations(body))
        else { return nil }
        return ImportedFact(
            kind: DistilledFactKind(rawValue: type.lowercased()) ?? .note,
            text: text,
            title: front["title"],
            createdAt: ImportDates.iso8601(front["timestamp"]),
            originalSource: ImportJSON.nonEmpty(front["source"]) ?? "okf"
        )
    }

    /// Frontmatter fields and the body after the closing `---`, or nil without frontmatter.
    private static func split(_ content: String) -> ([String: String], String)? {
        guard content.hasPrefix("---\n") else { return nil }
        let rest = content.dropFirst(4)
        guard let close = rest.range(of: "\n---\n") else { return nil }
        var fields: [String: String] = [:]
        for line in rest[..<close.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = unquoted(value)
        }
        return (fields, String(rest[close.upperBound...]))
    }

    /// Undo `OKFExport.quoted`: strip the quotes and resolve `\"` and `\\`.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var result = ""
        var escaping = false
        for character in value.dropFirst().dropLast() {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Cut the trailing Relations section — only when every line after the heading is a link,
    /// so a fact whose own text has such a heading keeps it.
    private static func withoutRelations(_ body: String) -> String {
        guard let heading = body.range(of: "\n## Relations\n", options: .backwards) else { return body }
        let tail = body[heading.upperBound...].split(separator: "\n")
        guard !tail.isEmpty, tail.allSatisfy({ $0.hasPrefix("- [") }) else { return body }
        return String(body[..<heading.lowerBound])
    }
}
