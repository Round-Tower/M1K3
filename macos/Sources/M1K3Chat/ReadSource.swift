//
//  ReadSource.swift
//  M1K3Chat
//
//  A text the user handed M1K3 to read: a paste, a file, a shared page. It rides
//  on the question's message (`ChatMessage.readSource`) so the text can be asked
//  about again and kept ("Keep this" files it as a document). Cleaned ONCE, here
//  (`ReadSanitizer`): what is stored, re-read and kept is what the brain saw.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-14, Confidence 0.85, Prior: none (new file)
//  Review: Kev + claude-opus-5.5, 2026-11-14 (the summoned pass on #833) — a source says when the cap
//  cut it (`capped`, so Keep's banner names the part kept), and decoding re-runs the sanitiser's
//  injection stages (`ReadSanitizer.recleaned`): "cleaned once" held only at `init?(title:raw:)`, so an
//  edited payload could hand a tokenizer raw text on "Ask more". Confidence 0.85.
//

import Foundation
import M1K3Inference

public struct ReadSource: Codable, Sendable, Equatable {
    /// What to call it: a filename, a page title, or "Pasted text".
    public let title: String
    /// The cleaned text.
    public let text: String
    /// True when the cap cut the text: Keep files only the first `characterCap` characters.
    public let capped: Bool

    /// The most text a source keeps after cleaning. A read sees a few thousand characters of it,
    /// and the source is stored with the conversation it was read in (the pre-push review: every
    /// save re-encodes it), so the cap is about twice a composer file's (FileTextExtractor: 50,000).
    public static let characterCap = 100_000

    /// A source from raw text, cleaned and capped; nil when nothing readable is left.
    public init?(title: String, raw: String) {
        let bounded = raw.count > Self.characterCap * 2 ? String(raw.prefix(Self.characterCap * 2)) : raw
        let whole = ReadSanitizer.clean(bounded)
        let cleaned = String(whole.prefix(Self.characterCap))
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.title = Self.cleanTitle(ReadSanitizer.clean(title))
        text = cleaned
        capped = bounded.count < raw.count || whole.count > Self.characterCap
    }

    /// The title reaches grounding, Spotlight and the banner (the security pass): cleaned like
    /// the text, one line, capped.
    private static func cleanTitle(_ cleaned: String) -> String {
        let name = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? pastedTitle : String(name.prefix(titleCap))
    }

    private enum CodingKeys: String, CodingKey { case title, text, capped }

    /// A stored source is cleaned AGAIN on the way back in: the payload is a file on disk, and
    /// everything downstream ("Ask more", Keep) trusts `text` to be clean. Only the injection
    /// stages run (`ReadSanitizer.recleaned`: invisibles, template tokens), which leave clean text
    /// unchanged, so an honest record decodes to itself. A record from before `capped` reads false.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedText = try container.decode(String.self, forKey: .text)
        text = String(ReadSanitizer.recleaned(storedText).prefix(Self.characterCap))
        title = try Self.cleanTitle(ReadSanitizer.recleaned(container.decode(String.self, forKey: .title)))
        capped = try container.decodeIfPresent(Bool.self, forKey: .capped) ?? false
    }

    /// The banner after "Keep this", saying so when only the first part of the text was kept.
    public func keptStatus(chunkCount: Int, deduped: Bool) -> String {
        let dedup = deduped ? String(localized: " (already kept)") : ""
        let part = capped
            ? String(localized: " (the first \(Self.characterCap.formatted()) characters)")
            : ""
        return String(localized: "Kept “\(title)”\(part) in Documents — \(chunkCount) chunks\(dedup).")
    }

    public static let pastedTitle = String(localized: "Pasted text")
    public static let titleCap = 120

    /// The composer's attached files as one source: one file keeps its name; several are each
    /// headed by their name, and the source is named for the first. nil when none has text.
    public init?(files: [FileAttachment]) {
        guard let first = files.first else { return nil }
        let raw = files.count == 1
            ? first.extractedText
            : files.map { "\($0.filename)\n\n\($0.extractedText)" }.joined(separator: "\n\n")
        let title = files.count == 1
            ? first.filename
            : String(localized: "\(first.filename) and \(files.count - 1) more")
        self.init(title: title, raw: raw)
    }

    /// One answered read: the text, and the newest question and answer about it.
    public struct Exchange: Sendable, Equatable {
        public let source: ReadSource
        public let question: String
        public let answer: String
    }
}

/// When a composer send is a READ rather than a chat turn (the challenger pass, 2026-11-14). A read
/// answers questions briefly from the text; it cannot write code, draft an email or translate. So a
/// file is read only when every file is prose and the words ask ABOUT it (blank, a question, a
/// summary). Anything else keeps today's chat turn, so a wrong call costs nothing new.
public enum ReadRoute {
    /// Prose and tabular text. Code and markup (html, xml, swift, js…) stay chat: the read's
    /// sanitiser would strip their tags, and their asks are usually "write" or "fix".
    public static let proseExtensions: Set<String> = ["txt", "text", "md", "markdown", "csv", "tsv", "log"]

    static let askingWords: Set<String> = [
        "what", "when", "where", "who", "whom", "whose", "which", "why", "how", "is", "are", "was", "were",
        "does", "do", "did", "can", "could", "should", "would", "will", "has", "have", "list", "summarise",
        "summarize", "summary", "tl", "tldr", "explain", "find", "any", "give",
    ]

    public static func reads(files: [FileAttachment], draft: String) -> Bool {
        guard !files.isEmpty, files.allSatisfy({ proseExtensions.contains(fileExtension($0.filename)) }) else {
            return false
        }
        return asks(draft)
    }

    /// Blank, ending in a question mark, or opening with a word that asks.
    static func asks(_ draft: String) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasSuffix("?") { return true }
        let first = trimmed.lowercased().split { !$0.isLetter }.first.map(String.init) ?? ""
        return askingWords.contains(first)
    }

    private static func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }
}
