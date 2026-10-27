import Foundation

public enum CodeBlockDetector {
    public static func detect(in text: String) -> [CodeArtifact] {
        var artifacts: [CodeArtifact] = []

        // <artifact title="…">…</artifact> — an explicit document the model marked
        // for the panel (rendered as markdown). Captured first, and its span removed
        // so the fence scan below doesn't also pick up any fences inside the body.
        var remaining = text
        for tagged in extractArtifactTags(from: text) {
            artifacts.append(
                CodeArtifact(source: tagged.source, language: .markdown, title: tagged.title)
            )
            remaining = remaining.replacingOccurrences(of: tagged.raw, with: "")
        }

        let fenced = extractFencedBlocks(from: remaining)
        for block in fenced {
            // A typed answer block (`m1k3-steps`, `m1k3-choices`, #717) renders as
            // a card in the bubble; surfacing it here would pop the review panel
            // with its raw JSON. Any `m1k3-` tag, so a later kind needs no edit
            // here and M1K3Preview stays dependency-free. (Tags arrive lowercased.)
            // Review: Kev + claude-opus-5.5, 2026-10-27 — this skip only; Prior: Unknown. Confidence 0.85.
            guard !block.tag.hasPrefix("m1k3-") else { continue }
            let language = resolveLanguage(tag: block.tag, source: block.source)
            guard let language else { continue }
            // A generic .code artifact carries its fence tag as the display label.
            let label = (language == .code && !block.tag.isEmpty) ? block.tag : nil
            artifacts.append(CodeArtifact(source: block.source, language: language, languageLabel: label))
        }

        if artifacts.isEmpty, looksLikeFullDocument(remaining) {
            artifacts.append(
                CodeArtifact(source: remaining.trimmingCharacters(in: .whitespacesAndNewlines), language: .html)
            )
        }

        return artifacts
    }

    private struct TaggedArtifact {
        let raw: String
        let title: String?
        let source: String
    }

    /// Extract `<artifact …>…</artifact>` blocks (case-insensitive, spanning
    /// newlines), pulling an optional `title="…"` attribute. Empty bodies are skipped.
    private static func extractArtifactTags(from text: String) -> [TaggedArtifact] {
        let block = /<artifact([^>]*)>(.*?)<\/artifact>/.ignoresCase().dotMatchesNewlines()
        var result: [TaggedArtifact] = []
        for match in text.matches(of: block) {
            let source = String(match.2).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }
            let title = String(match.1).firstMatch(of: /title\s*=\s*"([^"]*)"/.ignoresCase())
                .map { String($0.1) }
            result.append(TaggedArtifact(raw: String(match.0), title: title, source: source))
        }
        return result
    }

    private struct FencedBlock {
        let tag: String
        let source: String
    }

    private static func extractFencedBlocks(from text: String) -> [FencedBlock] {
        var blocks: [FencedBlock] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var idx = 0

        while idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let tag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                idx += 1
                var body: [String] = []
                while idx < lines.count {
                    let line = lines[idx].trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("```") {
                        break
                    }
                    body.append(lines[idx])
                    idx += 1
                }
                let source = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !source.isEmpty {
                    blocks.append(FencedBlock(tag: tag, source: source))
                }
            }
            idx += 1
        }

        return blocks
    }

    private static func resolveLanguage(tag: String, source: String) -> CodeArtifact.Language? {
        if !tag.isEmpty {
            switch tag {
            case "html", "htm": return .html
            case "css": return .css
            case "js", "javascript": return .js
            case "md", "markdown": return .markdown
            // Any other named language → a generic code artifact for the Code view.
            default: return .code
            }
        }
        return CodeArtifact.Language.detect(from: source)
    }

    private static func looksLikeFullDocument(_ text: String) -> Bool {
        let lines = text.lowercased()
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // A real document opens its <!doctype>/<html> at the START of a line, not
        // mid-sentence — so prose like "wrap it in <html> tags" doesn't fire the
        // panel. (The <head>/<body> arm below was already line-anchored.)
        if lines.contains(where: { $0.hasPrefix("<!doctype html") || $0.hasPrefix("<html") }) {
            return true
        }
        let hasHeadLine = lines.contains { $0.hasPrefix("<head") }
        let hasBodyLine = lines.contains { $0.hasPrefix("<body") }
        return hasHeadLine && hasBodyLine
    }
}
