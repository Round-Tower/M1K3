//
//  PageTextRecognizer.swift
//  M1K3Knowledge
//
//  Reads the text in a picture of a page: the seam PDFTextExtractor uses for scanned pages, which
//  have no text layer for PDFKit to find. The live reader is Vision's document recognizer, on the
//  device, so a scan never leaves it. Tests drive the extractor with a scripted fake.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.8 (Vision's document request is new in 26;
//  proven live on the Mac by ScannedPDFTests, the phone is a device check).
//  Prior: Tacit's VisionSceneScanner (accurate recognition with language correction), Kev.
//

import CoreGraphics
import Foundation
import Vision

/// Reads the text in one rendered page image.
public protocol PageTextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> String
}

/// Vision's document recognizer, on the device. Paragraph order comes from Vision's layout pass,
/// which keeps columns and headings in reading order better than line-by-line recognition.
public struct VisionPageTextRecognizer: PageTextRecognizing {
    public init() {}

    public func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        let observations = try await request.perform(on: image)
        return observations
            .map { observation in
                let paragraphs = observation.document.paragraphs.map(\.transcript)
                return paragraphs.isEmpty ? observation.document.text.transcript : paragraphs.joined(separator: "\n\n")
            }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
