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

import Foundation
import M1K3Memory

public enum ImportFormatDetector {
    /// Which provider exported `data`, or nil when it is neither shape.
    public static func detect(data: Data) -> ImportProvider? {
        (try? ImportJSON.root(of: data)).flatMap(detect(root:))
    }

    /// `.m1k3` when at least one file reads as an OKF fact.
    public static func detect(files: [OKFExport.File]) -> ImportProvider? {
        files.contains { OKFImportParser.fact(from: $0) != nil } ? .m1k3 : nil
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

    /// The first few conversations decide; a stray malformed element does not.
    static func detect(root: Any) -> ImportProvider? {
        guard let array = root as? [Any] else { return nil }
        for case let object as [String: Any] in array.prefix(5) {
            if object["mapping"] != nil { return .chatgpt }
            if object["chat_messages"] != nil { return .claude }
        }
        return nil
    }
}
