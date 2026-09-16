//
//  FileAttachment.swift
//  M1K3Inference
//
//  A document attached to a single chat turn — its extracted text rides the
//  turn as grounding context, not ingested into the permanent RAG corpus.
//  The difference: an image goes to the model's vision tower; a file goes to
//  the prompt as text the model can read and reason over.
//
//  Signed: Kev + claude-opus-4-6, 2026-09-16, Confidence 0.85,
//  Prior: ImageAttachment (the established pattern)
//  Review: Kev + claude-opus-4-6, 2026-09-17 — added UUID id for stable
//  ForEach identity (two files with the same name must not collide).
//

import Foundation

public struct FileAttachment: Identifiable, Sendable, Equatable, Hashable, Codable {
    public let id: UUID
    public let filename: String
    public let extractedText: String

    public init(id: UUID = UUID(), filename: String, extractedText: String) {
        self.id = id
        self.filename = filename
        self.extractedText = extractedText
    }

    public var contextBlock: String {
        """
        FILE: \(filename)
        ---
        \(extractedText)
        ---
        """
    }
}
