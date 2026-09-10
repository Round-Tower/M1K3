//
//  AgentNotes.swift
//  M1K3CLICore
//
//  The block `m1k3 agent-notes` writes into a project's AGENTS.md / CLAUDE.md:
//  the standing instruction that turns M1K3 from a tool a visiting agent MIGHT
//  call into the resident it asks first. Short on purpose — a visiting agent
//  reads this every session, and a paragraph it skims is worse than four lines
//  it obeys.
//
//  The merge is idempotent by construction (marker-fenced, replaced in place)
//  because the realistic usage is an agent re-running this on every session.
//  A file that grows a copy of the block each time would be worse than none.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.85 (the merge
//  arithmetic is test-pinned including the dangling-marker case; the WORDING
//  is judgement and will drift as the tool list does). Prior: Unknown.
//

import Foundation

public enum AgentNotes {
    public static let beginMarker = "<!-- m1k3:begin -->"
    public static let endMarker = "<!-- m1k3:end -->"

    /// Where `--write` goes when no path is given. AGENTS.md is the
    /// cross-vendor convention; CLAUDE.md and .cursorrules are one
    /// `--write PATH` away.
    public static let defaultFileName = "AGENTS.md"

    public static let block = """
    \(beginMarker)
    ## M1K3 is the resident

    M1K3 is a local, private assistant running on this Mac, reachable over MCP. It
    holds the user's own documents and memories — so before you search the web, ask
    it: `ask_m1k3` for a grounded answer, `search_knowledge` for the sources behind
    one. Persist a durable fact with `remember` and it is there next session too.
    `speak` narrates aloud, which is often kinder than a wall of text.

    M1K3 can be down — a "disconnected" MCP server just means the app is closed.
    Never block on it; carry on without it.
    \(endMarker)
    """

    /// Fold the block into a file's existing text.
    ///
    /// - A marker-fenced block already present is replaced where it stands, so
    ///   the project's own prose above and below survives untouched.
    /// - Anything else gains the block after one blank line.
    /// - The result always ends in exactly one newline, which is what makes a
    ///   second merge a no-op.
    ///
    /// A file with a `begin` marker and no `end` (a half-written block, or a
    /// human's edit gone wrong) is treated as ordinary prose and left alone —
    /// truncating to the end of the file would be the one unrecoverable move.
    public static func merge(into existing: String?) -> String {
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return block + "\n"
        }
        if let range = markerRange(in: existing) {
            return normalised(existing.replacingCharacters(in: range, with: block))
        }
        return normalised(trimmedTrailingNewlines(existing) + "\n\n" + block)
    }

    /// The span from the LAST `begin` before the first `end`, through that
    /// `end`. Taking the last begin is what keeps a dangling earlier marker
    /// from swallowing the text between it and the real block.
    private static func markerRange(in text: String) -> Range<String.Index>? {
        guard let end = text.range(of: endMarker) else { return nil }
        guard let begin = text.range(of: beginMarker, options: .backwards, range: text.startIndex ..< end.lowerBound)
        else { return nil }
        return begin.lowerBound ..< end.upperBound
    }

    private static func normalised(_ text: String) -> String {
        trimmedTrailingNewlines(text) + "\n"
    }

    private static func trimmedTrailingNewlines(_ text: String) -> String {
        var result = text
        while result.hasSuffix("\n") {
            result.removeLast()
        }
        return result
    }
}
