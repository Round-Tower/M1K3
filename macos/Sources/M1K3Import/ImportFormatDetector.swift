//
//  ImportFormatDetector.swift
//  M1K3Import
//
//  One drop target, three shapes (#711): a JSON array whose conversations carry `mapping` is a
//  ChatGPT export, `chat_messages` a Claude export, and a folder of frontmatter markdown another
//  M1K3's OKF export. Anything else is refused, never guessed at. `parse(data:)` reads the file
//  once and hands the parsed root to the right parser.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85.
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the first `sampleSize` conversation OBJECTS
//  decide (stray non-objects are skipped, not counted), the keys must have their types (`"mapping": null` is not
//  ChatGPT), and a folder is M1K3's only when a file carries the exporter's own `timestamp` and `source` (an Obsidian
//  or Hugo note with a `type:` key is not). Confidence 0.85.

import Foundation
import M1K3Memory

public enum ImportFormatDetector {
    /// Which provider exported `data`, or nil when it is neither shape.
    public static func detect(data: Data) -> ImportProvider? {
        (try? ImportJSON.root(of: data)).flatMap(detect(root:))
    }

    /// `.m1k3` when at least one file reads as a fact `OKFExport` wrote.
    public static func detect(files: [OKFExport.File]) -> ImportProvider? {
        files.contains(where: OKFImportParser.looksExported) ? .m1k3 : nil
    }

    /// Detect and parse in one read of the file.
    public static func parse(data: Data) throws -> ImportBundle {
        let root = try ImportJSON.root(of: data)
        switch detect(root: root) {
        case .chatgpt: return try ChatGPTExportParser.parse(root: root)
        case .claude: return try ClaudeExportParser.parse(root: root)
        case .m1k3, nil: throw ImportParseError.unrecognisedFormat
        }
    }

    /// How many conversation objects decide the format.
    static let sampleSize = 5

    /// The first `sampleSize` conversation objects decide; a stray non-object element is skipped
    /// rather than counted, and a key only counts with its type (`"mapping": null` is not ChatGPT).
    static func detect(root: Any) -> ImportProvider? {
        guard let array = root as? [Any] else { return nil }
        for object in array.lazy.compactMap({ $0 as? [String: Any] }).prefix(sampleSize) {
            if object["mapping"] is [String: Any] { return .chatgpt }
            if object["chat_messages"] is [Any] { return .claude }
        }
        return nil
    }
}
