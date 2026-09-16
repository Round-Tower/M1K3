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
//

import Foundation

public struct FileAttachment: Sendable, Equatable, Hashable, Codable {
    public let filename: String
    public let extractedText: String

    public init(filename: String, extractedText: String) {
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
