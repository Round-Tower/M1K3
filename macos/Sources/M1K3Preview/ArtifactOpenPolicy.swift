//
//  ArtifactOpenPolicy.swift
//  M1K3Preview
//
//  Which code opens beside the chat, and where it shows. Two questions, both
//  pure so the Mac, iPhone and iPad shells answer them the same way:
//
//    - The Open button on a code block opens THAT block (not the answer's first).
//    - An answer that lands, by any route (typed, voice, a look), opens the
//      page it made on its own — the first renderable artifact (HTML, or a
//      tagged markdown document). Plain code waits for its Open button.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.85, Prior: Unknown (new file)

import Foundation

public enum ArtifactOpenPolicy {
    /// The artifact behind one code block's Open button. `language` is the fence tag
    /// (nil or empty when untagged). A blank block opens nothing; anything else opens —
    /// as the language its tag names, sniffed from its source when untagged, else as
    /// generic code.
    public static func artifact(language: String?, code: String) -> CodeArtifact? {
        let source = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        let tag = (language ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if let detected = CodeBlockDetector.artifact(tag: tag, source: source) {
            return detected
        }
        return CodeArtifact(source: source, language: .code)
    }

    /// The artifact a finished answer's text opens by itself, from any route.
    public static func autoOpen(inAnswer text: String) -> CodeArtifact? {
        autoOpen(from: CodeBlockDetector.detect(in: text))
    }

    /// The artifact an answer opens by itself: the first renderable one, else nothing.
    public static func autoOpen(from artifacts: [CodeArtifact]) -> CodeArtifact? {
        artifacts.first { $0.language.isRenderable }
    }
}

/// Where the artifact view shows on a device.
public enum ArtifactPresentation: Equatable, Sendable {
    /// A sheet over the chat (iPhone, and iPad in a compact or narrow window).
    case sheet
    /// A column beside the chat (a wide, regular-width window).
    case besideChat

    /// The narrowest window (points) that keeps a readable chat beside the column. A half-width iPad
    /// Split View is still `.regular` but far narrower than this.
    public static let minimumBesideWidth: Double = 900

    public static func style(isRegularWidth: Bool, width: Double) -> ArtifactPresentation {
        isRegularWidth && width >= minimumBesideWidth ? .besideChat : .sheet
    }
}

/// An opened artifact and the conversation it was opened in. It shows only in that conversation, so a
/// new chat, a delete or a switch leaves no stale page beside the wrong transcript.
public struct ScopedArtifact: Equatable, Sendable {
    public let artifact: CodeArtifact
    public let conversationID: UUID

    public init(_ artifact: CodeArtifact, conversationID: UUID) {
        self.artifact = artifact
        self.conversationID = conversationID
    }

    public func visible(in conversationID: UUID) -> CodeArtifact? {
        self.conversationID == conversationID ? artifact : nil
    }
}
