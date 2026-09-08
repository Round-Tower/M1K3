//
//  NarrationCaption.swift
//  M1K3Voice
//
//  Who is talking through M1K3's voice right now — the caption under the
//  notch HUD's scrolling narration (hit list 2026-09-08, item 2: "name the
//  talking agent, not the brain"). M1K3's own answers say M1K3; a visiting
//  agent speaking over MCP is named by the client name it announced at
//  initialize, "via M1K3" so the voice and the author never get conflated.
//  Pure: the app passes the narrator in with the utterance.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.85 (four pinned
//  cases; the prettifying of client names is taste). Prior: Unknown.
//

import Foundation

/// The author of an utterance M1K3 is voicing.
public enum Narrator: Equatable, Sendable {
    /// M1K3 itself — chat auto-speak, voice mode, the heartbeat.
    case m1k3
    /// An MCP client, by the name it gave at initialize (nil when it gave none).
    case visitor(String?)
}

public enum NarrationCaption {
    public static let fallbackVisitor = "A VISITING AGENT"
    /// The client name is UNTRUSTED display data (any process can claim any
    /// name at initialize) and the HUD line is fixed-width — cap it here, so
    /// no caller can push a paragraph into the pill.
    public static let maxNameLength = 24

    /// Uppercase, the HUD's house register. `claude-code` → `CLAUDE CODE · VIA M1K3`.
    public static func text(for narrator: Narrator) -> String {
        switch narrator {
        case .m1k3:
            return "M1K3"
        case let .visitor(name):
            let shown = displayName(name)
            return "\(shown) · VIA M1K3"
        }
    }

    /// One line, printable, capped: control characters and newlines dropped,
    /// runs of whitespace/dashes/underscores folded to one space, then cut at
    /// `maxNameLength` with an ellipsis.
    static func displayName(_ raw: String?) -> String {
        guard let raw else { return fallbackVisitor }
        // Control characters (newlines included) become a space, so a name
        // split across lines still reads as words on the one HUD line.
        // Scalar-level replace, then back to a String so multi-scalar
        // grapheme clusters (ZWJ emoji, combining marks) stay intact.
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let isControl = CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
            scalars.append(isControl ? " " : scalar)
        }
        let folded = String(scalars)
            .replacingOccurrences(of: "[-_\\s]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        guard !folded.isEmpty else { return fallbackVisitor }
        guard folded.count > maxNameLength else { return folded }
        return String(folded.prefix(maxNameLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
