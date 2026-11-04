//
//  PDFTextExtractor.swift
//  M1K3Knowledge
//
//  Thin PDFKit adapter: a PDF (data or file) → ordered [DocumentPage] for the
//  chunker. PDFKit ships with macOS, so this adds no third-party dependency.
//
//  Mirrors the prior knowledge-server's PDFTextExtractor. Kept deliberately minimal — the testable
//  logic (boilerplate strip, sectioning, windowing) lives in DocumentChunker;
//  this is the I/O boundary, verified by a generated-PDF round-trip.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85,
//  Prior: internal knowledge-server project, PDFTextExtractor.swift (Kev)
//  Review: Kev + claude-opus-5.5, 2026-11-03 — scanned pages. A page with no text layer (fewer than
//  `minimumLetters` letters: blank, or only a page number or stamp) is rendered and read by a
//  `PageTextRecognizing` (Vision on the device). Up to `defaultMaxScannedPages` per file; the rest are
//  counted in `ScanReport.skipped`, never dropped silently. A recognizer failure leaves that page empty.
//  The first App Store review (2026-11-01) hit this: a scan indexed as its title alone. Confidence 0.8.
//  Review (same day, pre-push review): failures are counted (`ScanReport.failed`), a cancel is rethrown
//  instead of read as a failed page, each render drains in an autorelease pool, and pages render from the
//  crop box. Confidence 0.8.
//

import CoreGraphics
import Foundation
import PDFKit

public enum PDFTextExtractor {
    public enum ExtractError: Error, Sendable {
        case cannotOpen
        case empty
    }

    /// Scanned pages read from their images, pages the reader couldn't read, and pages past the cap.
    public struct ScanReport: Sendable, Equatable {
        public var read: Int
        public var failed: Int
        public var skipped: Int

        public init(read: Int, failed: Int = 0, skipped: Int) {
            self.read = read
            self.failed = failed
            self.skipped = skipped
        }

        public static let none = ScanReport(read: 0, skipped: 0)
    }

    /// Reported before each scanned page is read: page `page` of the `of` that will be read.
    public struct ScanProgress: Sendable, Equatable {
        public var page: Int
        public var of: Int

        public init(page: Int, of: Int) {
            self.page = page
            self.of = of
        }
    }

    /// A page with fewer letters than this has no real text layer.
    static let minimumLetters = 16
    /// About a minute of reading on a phone; a longer scan says how many pages it skipped.
    public static let defaultMaxScannedPages = 100
    /// Long edge of a rendered page, in pixels: about 200 dpi on A4, enough for body text.
    static let renderLongEdge: CGFloat = 2200

    /// Extract per-page text from PDF bytes. Page numbers are 1-based.
    public static func extract(data: Data) throws -> [DocumentPage] {
        guard let document = PDFDocument(data: data) else { throw ExtractError.cannotOpen }
        return try pages(from: document)
    }

    /// Extract per-page text from a PDF file URL.
    public static func extract(url: URL) throws -> [DocumentPage] {
        guard let document = PDFDocument(url: url) else { throw ExtractError.cannotOpen }
        return try pages(from: document)
    }

    /// Extract per-page text, reading pages that have no text layer with `recognizer`.
    public static func extract(
        data: Data,
        recognizer: (any PageTextRecognizing)?,
        maxScannedPages: Int = defaultMaxScannedPages,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> (pages: [DocumentPage], scans: ScanReport) {
        guard let document = PDFDocument(data: data) else { throw ExtractError.cannotOpen }
        var pages = try pages(from: document)
        guard let recognizer else { return (pages, .none) }

        let scanned = pages.indices.filter { needsRecognition(pages[$0].text) }
        let toRead = Array(scanned.prefix(max(0, maxScannedPages)))
        var read = 0, failed = 0
        for (step, index) in toRead.enumerated() {
            try Task.checkCancellation()
            progress?(ScanProgress(page: step + 1, of: toRead.count))
            // One rendered page alive at a time (about 14 MB): the pool drains it before the next.
            guard let image = autoreleasepool(invoking: { document.page(at: index).flatMap(render) }) else {
                failed += 1
                continue
            }
            let text: String
            do {
                text = try await recognizer.recognizeText(in: image)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
                continue
            }
            if letterCount(text) > letterCount(pages[index].text) {
                pages[index] = DocumentPage(pageNumber: pages[index].pageNumber, text: text)
                read += 1
            }
        }
        try Task.checkCancellation()
        return (pages, ScanReport(read: read, failed: failed, skipped: scanned.count - toRead.count))
    }

    /// True when a page's text layer is missing or holds only a page number or a stamp.
    static func needsRecognition(_ text: String) -> Bool {
        letterCount(text) < minimumLetters
    }

    private static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.letters.contains($1) ? 1 : 0) }
    }

    /// The page drawn on white at `renderLongEdge`, honouring its /Rotate (CGPDFPage's drawing
    /// transform does the rotation and the fit). The crop box, as PDFKit shows the page.
    static func render(_ page: PDFPage) -> CGImage? {
        guard let cgPage = page.pageRef else { return nil }
        let box = cgPage.getBoxRect(.cropBox)
        let quarterTurned = (cgPage.rotationAngle / 90) % 2 != 0
        let size = quarterTurned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = renderLongEdge / max(size.width, size.height)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(target)
        ctx.concatenate(cgPage.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(cgPage)
        return ctx.makeImage()
    }

    private static func pages(from document: PDFDocument) throws -> [DocumentPage] {
        guard document.pageCount > 0 else { throw ExtractError.empty }
        var out: [DocumentPage] = []
        out.reserveCapacity(document.pageCount)
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            out.append(DocumentPage(pageNumber: index + 1, text: page.string ?? ""))
        }
        return out
    }
}
