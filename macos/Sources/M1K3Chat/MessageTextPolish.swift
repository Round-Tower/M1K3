//
//  MessageTextPolish.swift
//  M1K3Chat
//
//  Models emit markdown. ReadingText used to render PLAIN text, so this file's
//  whole job was flattening **bold**/*italic*/`code`/#headings away before the
//  bubble ever saw them. As of the markdown/code-highlighting pass (2026-07-22)
//  ReadingText renders real markdown blocks (ChatMarkdownParser) — flattening
//  the markup here would just delete the structure the renderer now depends on.
//  So this is down to a whitespace-only tidy: collapsing blank-line pile-ups
//  (the "Web sources" gap models leave), skipping fenced code blocks AND
//  <artifact>…</artifact> document blocks so neither loses meaningful
//  whitespace (indentation, deliberate blank lines in a snippet). Citation
//  tokens ([Title §heading], no following parenthesis) were never touched by
//  the old flattening either — nothing here does anything to them.
//
//  Runs once on the FINAL message text (ChatSession rewrites it at completion
//  after citation validation), so streaming shows raw tokens for a moment and
//  then settles clean.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-4-8, 2026-06-29, Confidence 0.85 — fenced code
//  blocks are now preserved VERBATIM. Flattening ran over generated code too,
//  eating `#`-comment / heading lines and stripping backticks and **bold** —
//  mangled code reads as "won't generate code properly". Only the prose between
//  fences is flattened for ReadingText now. (Limitation: UNfenced code can't be
//  told from prose, so it's still flattened — models reliably fence code blocks,
//  and the app surfaces the first fence in a code webview regardless.)
//  Review: Kev + claude-fable-5, 2026-07-02, Confidence 0.9 — fence pairing is
//  now LINE-BASED (CommonMark run-length), replacing the non-greedy regex that
//  split early on an inline ``` in the fence body and dropped UNCLOSED
//  (token-truncated) fences into prose polishing — both mangled code. Unclosed
//  fences/artifacts now run verbatim to the end, and CRLF pairs correctly
//  (\r\n is ONE grapheme — search \.isNewline, never == "\n"; the pin test
//  caught this). Review-debt paydown: #109-2, #109-14.
//  Review: Kev + claude-sonnet-5, 2026-07-22, Confidence 0.85 — the chat
//  bubble now renders real markdown blocks and highlighted code (ChatMarkdown-
//  Parser + CodeSyntaxHighlighter in ReadingText), so flattening bold/italic/
//  backticks/headings/bullets/links here would destroy the very structure the
//  renderer needs. All of that stripping is gone; only the blank-line collapse
//  survives, still fence/artifact-safe. Kept the function name and the fence/
//  artifact-preserving scan (still needed so the collapse can't mangle a
//  snippet's or a document's deliberate whitespace) — only `polishProse`'s
//  BODY changed.
import Foundation

public enum MessageTextPolish {
    /// Tidy blank-line pile-ups in prose while leaving fenced code blocks
    /// (```…```) and `<artifact>` document blocks untouched. Splits on those
    /// regions, tidies only the prose segments, then trims the joined result
    /// once. Markdown markup (headings, emphasis, links, bullets) is left
    /// exactly as the model wrote it — ChatMarkdownParser renders it.
    public static func polish(_ text: String) -> String {
        // Regions left byte-for-byte: fenced code blocks AND <artifact>…</artifact>
        // document blocks — the markdown inside an artifact must survive verbatim so
        // the review panel can render it (flattening would strip its structure first).
        var ranges = fencedCodeRanges(in: text)
        for match in text.matches(of: /<artifact(?:[^>]*)>(?s:.*?)<\/artifact>/.ignoresCase()) {
            ranges.append(match.range)
        }
        if let truncated = unclosedArtifactStart(in: text, coveredBy: ranges) {
            ranges.append(truncated ..< text.endIndex)
        }
        // Ranges may OVERLAP (an unclosed <artifact> spans to the end, superset
        // of any fence inside it) — the nested-region guard in the emit loop
        // below is what restores the no-overlap invariant, not this sort. A
        // range STRADDLING a prior range's end (a fence crossing an artifact's
        // closing tag) is dropped by the same guard; its tail flattens as prose
        // — contrived enough to accept rather than special-case.
        ranges.sort { $0.lowerBound < $1.lowerBound }

        var result = ""
        var cursor = text.startIndex
        for range in ranges {
            // Skip a region nested in one already emitted (e.g. a fence inside an
            // <artifact> — the artifact span already covers it).
            guard range.lowerBound >= cursor else { continue }
            result += polishProse(String(text[cursor ..< range.lowerBound]))
            result += String(text[range]) // verbatim
            cursor = range.upperBound
        }
        result += polishProse(String(text[cursor...]))
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Line-based fence pairing (CommonMark run-length rules, replacing an
    /// earlier non-greedy regex): an opening fence is a line whose first
    /// non-whitespace run is 3+ backticks (any indent — see below), and it
    /// closes only on a LINE-LEADING run at least as long with nothing after
    /// but whitespace. Two failure modes of the regex
    /// this kills: an inline ``` inside the fence body split the block early, and
    /// an UNCLOSED fence (max-token truncation mid-code) matched nothing at all —
    /// both dropped the code tail into `polishProse`, which eats `#`-comment
    /// lines and strips backticks/bold. An unclosed fence now runs verbatim to
    /// the end: raw markdown beats mangled code.
    private static func fencedCodeRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var openStart: String.Index?
        var openRun = 0
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            // \.isNewline, not == "\n": Swift folds "\r\n" into ONE grapheme, so
            // a literal-\n search would see a CRLF text as a single line and
            // never pair its fences.
            let newline = text[lineStart...].firstIndex(where: \.isNewline)
            let contentEnd = newline ?? text.endIndex
            let nextLine = newline.map { text.index(after: $0) } ?? text.endIndex
            let line = text[lineStart ..< contentEnd]
            // ANY leading whitespace is tolerated (wider than CommonMark's
            // 3-space rule, on purpose): models nest fences 4+ deep under list
            // items, and this file's job is "don't mangle code" — a too-strict
            // net drops real code into polishProse.
            let unindented = line.drop { $0 == " " || $0 == "\t" }
            let run = unindented.prefix { $0 == "`" }.count
            if let start = openStart {
                if run >= openRun, unindented.dropFirst(run).allSatisfy(\.isWhitespace) {
                    ranges.append(start ..< contentEnd)
                    openStart = nil
                }
            } else if run >= 3, !unindented.dropFirst(run).contains("`") {
                // The no-backticks-after condition is CommonMark's own: a fence
                // opener's info string may not contain backticks. It keeps a
                // line-leading same-line span (```code``` prose…) OUT of fence
                // detection — misreading one as an unclosed opener would swallow
                // the rest of the message verbatim. It stays prose: here that
                // just means the whitespace tidy may touch it (the renderer
                // owns span styling now); SpeechTextPolish's twin scanner is
                // where the span actually flattens, for speech.
                openStart = lineStart
                openRun = run
            }
            lineStart = nextLine
        }
        if let start = openStart {
            ranges.append(start ..< text.endIndex)
        }
        return ranges
    }

    /// A truncated `<artifact …>` with no closing tag anywhere after it (the
    /// generation hit its token limit mid-document): verbatim from the tag to
    /// the end, same rule as an unclosed fence. Occurrences already inside a
    /// covered region (a fence, or a closed artifact) don't count.
    private static func unclosedArtifactStart(
        in text: String, coveredBy ranges: [Range<String.Index>]
    ) -> String.Index? {
        var search = text.startIndex
        while let open = text.range(
            of: "<artifact", options: .caseInsensitive, range: search ..< text.endIndex
        ) {
            search = open.upperBound
            if ranges.contains(where: { $0.contains(open.lowerBound) }) { continue }
            let rest = open.lowerBound ..< text.endIndex
            if text.range(of: "</artifact>", options: .caseInsensitive, range: rest) == nil {
                return open.lowerBound
            }
        }
        return nil
    }

    /// The whitespace-only tidy, applied to non-code, non-artifact prose.
    private static func polishProse(_ text: String) -> String {
        // Newline pile-ups (the "Web sources" gap) collapse to one blank line.
        // Everything else markdown produces (headings, emphasis, links, code
        // spans, bullets) is left exactly as written — ChatMarkdownParser and
        // ReadingText render it for real now, so there is nothing left to strip.
        text.replacing(/\n{3,}/) { _ in "\n\n" }
    }
}
