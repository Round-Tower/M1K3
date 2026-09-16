//
//  FileTextExtractor.swift
//  M1K3Inference
//
//  Extract readable text from common document formats for the file-as-context
//  feature: a dropped file becomes turn context (not a permanent RAG ingest).
//  Text-based formats only (plain text, source code, markup) — PDF extraction
//  lives in M1K3Knowledge where PDFKit is available. Dependency-free.
//
//  Signed: Kev + claude-opus-4-6, 2026-09-16, Confidence 0.85,
//  Prior: PDFTextExtractor in M1K3Knowledge (the RAG ingest path)
//

import Foundation

public enum FileTextExtractor {
    public enum ExtractionError: Error, Sendable, Equatable {
        case unsupportedFormat(String)
        case readFailed(String)
        case emptyContent
    }

    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "swift", "py", "js", "ts", "json",
        "yaml", "yml", "toml", "xml", "html", "css", "sh", "zsh", "bash",
        "c", "h", "cpp", "rs", "go", "rb", "java", "kt", "scala", "r",
        "sql", "csv", "log", "conf", "ini",
    ]

    /// Extract text from a file URL. Supports text-based formats (source code,
    /// markup, config). PDF extraction is handled by the app target (PDFKit).
    /// The URL must be security-scoped if from a file importer.
    public static func extract(from url: URL) throws -> FileAttachment {
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        let text: String
        if textExtensions.contains(ext) {
            text = try String(contentsOf: url, encoding: .utf8)
        } else if let plainText = try? String(contentsOf: url, encoding: .utf8),
                  plainText.unicodeScalars.allSatisfy({ !$0.properties.isNoncharacterCodePoint })
        {
            text = plainText
        } else {
            throw ExtractionError.unsupportedFormat(ext)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExtractionError.emptyContent }

        return FileAttachment(filename: filename, extractedText: trimmed)
    }
}
