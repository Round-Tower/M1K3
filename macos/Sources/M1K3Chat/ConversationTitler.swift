//
//  ConversationTitler.swift
//  M1K3Chat
//
//  Auto-titling for the history drawer: after the first completed exchange of
//  an untitled conversation, ChatSession fires the titler in the background
//  (never blocking send) and stores the sanitized result. Small local models
//  return messy strings — quotes, "Title:" prefixes, whole paragraphs — so
//  TitleSanitizer is where the real behaviour lives, and a nil from it means
//  "stay untitled, retry after the next exchange".
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.85 (pure parts
//  test-pinned; title quality on the real lineup is verify-at-⌘R).
//  Prior: Unknown.
//

import Foundation
import M1K3Inference

public protocol ConversationTitling: Sendable {
    /// RAW model output — the caller sanitizes (keeps the seam dumb and the
    /// sanitizer's behaviour in one tested place).
    func title(forUser user: String, assistant: String) async throws -> String
}

public struct ProviderConversationTitler: ConversationTitling {
    private let provider: any InferenceProvider

    public init(provider: any InferenceProvider) {
        self.provider = provider
    }

    public func title(forUser user: String, assistant: String) async throws -> String {
        // Nobody is waiting on a title. Marked background so it can never take
        // the persona-prefix slot from the chat turn that just finished — the
        // 2026-08-09 finding, where exactly this call cost the NEXT turn 16-19s.
        try await InferenceIntent.backgroundUtility {
            try await provider.generate(prompt: TitlePrompt.build(user: user, assistant: assistant))
        }
    }
}

public enum TitlePrompt {
    /// Both turns capped at 400 chars (HistoryWindow's per-turn budget) —
    /// titling must stay cheap enough to fire after every send if needed.
    public static func build(user: String, assistant: String) -> String {
        """
        Write a 3-6 word title for this conversation. Reply with ONLY the title — \
        no quotes, no punctuation at the end, no explanation.

        USER: \(String(user.prefix(400)))
        ASSISTANT: \(String(assistant.prefix(400)))
        """
    }
}

public enum TitleSanitizer {
    /// nil = unusable output; the conversation stays untitled.
    public static func sanitize(_ raw: String) -> String? {
        // First non-empty line only — models love to explain themselves.
        guard var line = raw
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        if let range = line.range(of: "Title:", options: [.caseInsensitive, .anchored]) {
            line = String(line[range.upperBound...])
        }
        // Quotes and trailing punctuation interleave ("Echo chat". ) — strip
        // to a fixed point, not in one pass.
        let quotes = CharacterSet(charactersIn: "\"'`“”‘’ ")
        var previous: String
        repeat {
            previous = line
            line = line.trimmingCharacters(in: quotes)
            while let last = line.last, ".!?,;:".contains(last) {
                line.removeLast()
            }
        } while line != previous
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        if line.count > 60 {
            // Cut on a word boundary under the cap.
            var words: [Substring] = []
            var length = 0
            for word in line.split(separator: " ") {
                let next = length + (words.isEmpty ? 0 : 1) + word.count
                if next > 60 { break }
                words.append(word)
                length = next
            }
            line = words.joined(separator: " ")
        }
        return line.isEmpty ? nil : line
    }
}
