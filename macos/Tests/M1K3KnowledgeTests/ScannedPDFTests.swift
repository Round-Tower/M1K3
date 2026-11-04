//
//  ScannedPDFTests.swift
//  M1K3KnowledgeTests
//
//  A scanned PDF is pictures of pages: PDFKit finds no text, so before this M1K3 indexed the title
//  alone and later told the user the file had "no readable text" (the first App Store review,
//  iPhone, 2026-11-01). Pages with no text layer are now read with on-device text recognition, and a
//  file that still yields nothing is refused at import, by name, instead of indexed empty.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.8 (the fake recognizer pins the policy; one
//  live Vision test proves the real path on this Mac). Prior: Unknown.
//

import CoreGraphics
import CoreText
import Foundation
@testable import M1K3Knowledge
import PDFKit
import Testing

// MARK: - Helpers

/// A PDF whose pages are images of text, with no text layer: what a phone scan or a scanner makes.
func makeScannedPDF(pages: [String], fontSize: CGFloat = 28) -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
    for text in pages {
        pdf.beginPDFPage(nil)
        if let image = renderTextImage(text, size: CGSize(width: 1224, height: 1584), fontSize: fontSize * 2) {
            pdf.draw(image, in: mediaBox)
        }
        pdf.endPDFPage()
    }
    pdf.closePDF()
    return data as Data
}

/// Black text on white, rasterised: no glyphs survive into the PDF.
private func renderTextImage(_ text: String, size: CGSize, fontSize: CGFloat) -> CGImage? {
    guard let ctx = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: size))
    guard !text.isEmpty else { return ctx.makeImage() }
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
    ])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: CGRect(x: 80, y: 80, width: size.width - 160, height: size.height - 160), transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, ctx)
    return ctx.makeImage()
}

/// A PDF with a real text layer (what a word processor exports).
private func makeTextPDF(pages: [String]) -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
    let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    for text in pages {
        ctx.beginPDFPage(nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 36, y: 36, width: 540, height: 720), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return data as Data
}

/// Answers each call with the next scripted reply (or throws), and counts the calls.
final class ScriptedRecognizer: PageTextRecognizing, @unchecked Sendable {
    enum Reply { case text(String), failure }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var calls = 0

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func recognizeText(in _: CGImage) async throws -> String {
        let reply: Reply = lock.withLock {
            calls += 1
            return replies.isEmpty ? .text("") : replies.removeFirst()
        }
        switch reply {
        case let .text(text): return text
        case .failure: throw CocoaError(.featureUnsupported)
        }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var steps: [PDFTextExtractor.ScanProgress] = []
    func record(_ step: PDFTextExtractor.ScanProgress) {
        lock.withLock { steps.append(step) }
    }
}

// MARK: - Which pages need reading

struct ScannedPagePolicyTests {
    @Test("a page with no text, or only a page number or stamp, is read from its image")
    func emptyPagesNeedRecognition() {
        #expect(PDFTextExtractor.needsRecognition(""))
        #expect(PDFTextExtractor.needsRecognition("  \n\t "))
        #expect(PDFTextExtractor.needsRecognition("3"))
        #expect(PDFTextExtractor.needsRecognition("Page 3 of 12"))
    }

    @Test("a page with a real text layer is left alone")
    func textPagesKeepTheirLayer() {
        #expect(!PDFTextExtractor.needsRecognition("The lease runs from March to February, rent due monthly."))
    }
}

// MARK: - Extraction with a recognizer

struct ScannedPDFExtractionTests {
    @Test("control: PDFKit alone finds no text in a scanned page")
    func pdfKitAloneFindsNothing() throws {
        let pages = try PDFTextExtractor.extract(data: makeScannedPDF(pages: ["Invoice total 4,250 euros"]))
        #expect(pages.count == 1)
        #expect(pages[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("only the scanned pages are recognised; text pages and page numbers are kept")
    func recognisesOnlyScannedPages() async throws {
        // Page 1 has a text layer, page 2 is a scan. Build one PDF from both by appending.
        let text = try #require(PDFDocument(data: makeTextPDF(pages: ["A real text layer on page one."])))
        let scan = try #require(PDFDocument(data: makeScannedPDF(pages: ["scanned"])))
        try text.insert(#require(scan.page(at: 0)), at: text.pageCount)
        let merged = try #require(text.dataRepresentation())
        let recognizer = ScriptedRecognizer([.text("Scanned page two, read by Vision.")])
        let log = ProgressLog()

        let result = try await PDFTextExtractor.extract(
            data: merged, recognizer: recognizer, progress: { log.record($0) }
        )

        #expect(recognizer.calls == 1)
        #expect(result.pages.map(\.pageNumber) == [1, 2])
        #expect(result.pages[0].text.contains("real text layer"))
        #expect(result.pages[1].text == "Scanned page two, read by Vision.")
        #expect(result.scans == PDFTextExtractor.ScanReport(read: 1, skipped: 0))
        #expect(log.steps == [PDFTextExtractor.ScanProgress(page: 1, of: 1)])
    }

    @Test("a page the recognizer fails on stays empty; the rest still read")
    func failureOnOnePageIsNotFatal() async throws {
        let data = makeScannedPDF(pages: ["one", "two"])
        let recognizer = ScriptedRecognizer([.failure, .text("Second page text.")])

        let result = try await PDFTextExtractor.extract(data: data, recognizer: recognizer)

        #expect(result.pages.count == 2)
        #expect(result.pages[0].text.isEmpty)
        #expect(result.pages[1].text == "Second page text.")
        #expect(result.scans == PDFTextExtractor.ScanReport(read: 1, failed: 1, skipped: 0))
    }

    @Test("past the cap, scanned pages are skipped and counted, never silently dropped")
    func capIsReported() async throws {
        let data = makeScannedPDF(pages: ["a", "b", "c"])
        let recognizer = ScriptedRecognizer([.text("A."), .text("B."), .text("C.")])

        let result = try await PDFTextExtractor.extract(data: data, recognizer: recognizer, maxScannedPages: 2)

        #expect(recognizer.calls == 2)
        #expect(result.scans == PDFTextExtractor.ScanReport(read: 2, skipped: 1))
        #expect(result.pages[2].text.isEmpty)
    }

    @Test("a cancel during recognition stops the import, not just the page")
    func cancelIsRethrown() async throws {
        struct Cancelling: PageTextRecognizing {
            func recognizeText(in _: CGImage) async throws -> String {
                throw CancellationError()
            }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await PDFTextExtractor.extract(data: makeScannedPDF(pages: ["a", "b"]), recognizer: Cancelling())
        }
    }

    @Test("a quarter-turned page renders on its side (its /Rotate is honoured)")
    func rotatedPageRendersTurned() throws {
        let document = try #require(PDFDocument(data: makeScannedPDF(pages: ["x"])))
        let page = try #require(document.page(at: 0))
        page.rotation = 90
        let rotatedData = try #require(document.dataRepresentation())
        let reopened = try #require(PDFDocument(data: rotatedData)?.page(at: 0))
        let image = try #require(PDFTextExtractor.render(reopened))
        #expect(image.width > image.height)
        #expect(max(image.width, image.height) == 2200)
    }

    @Test("no recognizer: the old behaviour, scanned pages stay empty")
    func noRecognizerKeepsOldBehaviour() async throws {
        let result = try await PDFTextExtractor.extract(data: makeScannedPDF(pages: ["x"]), recognizer: nil)
        #expect(result.pages[0].text.isEmpty)
        #expect(result.scans == PDFTextExtractor.ScanReport(read: 0, skipped: 0))
    }

    /// Opt-in (`M1K3_OCR_LIVE=1`): Vision's first call in a process takes 30 s or more while it loads,
    /// too slow and too variable for the CI runner. Run locally after touching the recognizer.
    @Test(
        "LIVE: Vision reads a scanned page on this machine",
        .enabled(if: ProcessInfo.processInfo.environment["M1K3_OCR_LIVE"] == "1"),
        .timeLimit(.minutes(3))
    )
    func visionReadsAScan() async throws {
        let data = makeScannedPDF(pages: ["The quarterly invoice total is 4,250 euros, due on the ninth of March."])
        let result = try await PDFTextExtractor.extract(data: data, recognizer: VisionPageTextRecognizer())
        let text = result.pages[0].text.lowercased()
        #expect(text.contains("invoice"), "Vision read: \(text)")
        #expect(text.contains("4,250") || text.contains("4250"), "Vision read: \(text)")
        #expect(result.scans.read == 1)
    }
}

// MARK: - Ingest

struct ScannedPDFIngestTests {
    @Test("a scanned PDF ingests its recognised text and is searchable")
    func scannedPDFBecomesSearchable() async throws {
        let store = try KnowledgeStore()
        let recognizer = ScriptedRecognizer([.text("The boiler service is booked for the fourteenth of November.")])
        let ingester = DocumentIngester(store: store, recognizer: recognizer)

        let result = try await ingester.ingestPDF(
            title: "Boiler letter", data: makeScannedPDF(pages: ["x"]), sourceRef: "file:///boiler.pdf"
        )

        #expect(result.chunkCount > 0)
        #expect(result.scans == PDFTextExtractor.ScanReport(read: 1, skipped: 0))
        let hits = try store.searchFTS(query: "boiler")
        #expect(hits.contains { $0.content.contains("boiler service") })
    }

    @Test("a PDF with no text anywhere is refused by name and nothing is indexed")
    func emptyScanIsRefused() async throws {
        let store = try KnowledgeStore()
        let ingester = DocumentIngester(store: store, recognizer: ScriptedRecognizer([.text("")]))

        await #expect(throws: DocumentIngester.IngestError.noReadableText) {
            try await ingester.ingestPDF(title: "Blank", data: makeScannedPDF(pages: [""]), sourceRef: "file:///b.pdf")
        }
        #expect(try store.itemCount() == 0)
    }

    @Test("an empty text file is refused with its own error")
    func emptyTextIsRefused() async throws {
        let store = try KnowledgeStore()
        let ingester = DocumentIngester(store: store)
        await #expect(throws: DocumentIngester.IngestError.emptyText) {
            try await ingester.ingest(title: "Empty", text: "  \n ", sourceRef: "file:///e.txt")
        }
        #expect(try store.itemCount() == 0)
    }

    @Test("re-importing a file that was indexed empty reads it again instead of deduping")
    func emptyEarlierImportIsReplaced() async throws {
        let store = try KnowledgeStore()
        // What 1.2.1 left behind: the title alone, no chunks, under the file's sourceRef.
        let stale = try await DocumentIngester(store: store, recognizer: nil)
            .ingest(title: "Lease", pages: [DocumentPage(pageNumber: 1, text: "")], sourceRef: "file:///lease.pdf")
        #expect(stale.chunkCount == 0)

        let recognizer = ScriptedRecognizer([.text("The lease runs from March to February, rent due monthly.")])
        let result = try await DocumentIngester(store: store, recognizer: recognizer)
            .ingestPDF(title: "Lease", data: makeScannedPDF(pages: ["x"]), sourceRef: "file:///lease.pdf")

        #expect(!result.wasDeduped)
        #expect(result.chunkCount > 0)
        #expect(try store.itemCount() == 1)
    }

    @Test("every scanned page failing blames the reader, not the file")
    func unreadableScanBlamesTheReader() async throws {
        let store = try KnowledgeStore()
        let ingester = DocumentIngester(store: store, recognizer: ScriptedRecognizer([.failure, .failure]))
        await #expect(throws: DocumentIngester.IngestError.scanUnreadable) {
            try await ingester.ingestPDF(title: "Scan", data: makeScannedPDF(pages: ["a", "b"]), sourceRef: "file:///s.pdf")
        }
        #expect(try store.itemCount() == 0)
    }

    @Test("an empty earlier item of another kind still dedupes: only documents are replaced")
    func onlyDocumentsAreReplaced() async throws {
        let store = try KnowledgeStore()
        let ingester = DocumentIngester(store: store, recognizer: nil)
        let first = try await ingester.ingest(
            title: "Chat", pages: [DocumentPage(pageNumber: 1, text: "")], sourceRef: "conv:1", kind: .conversation
        )
        let again = try await ingester.ingest(
            title: "Chat", pages: [DocumentPage(pageNumber: 1, text: "")], sourceRef: "conv:1", kind: .conversation
        )
        #expect(again.wasDeduped)
        #expect(again.itemID == first.itemID)
    }

    @Test("a file already indexed WITH text still dedupes")
    func realDuplicateStillDedupes() async throws {
        let store = try KnowledgeStore()
        let ingester = DocumentIngester(store: store)
        let notes = "Some real notes here."
        let first = try await ingester.ingest(title: "Notes", text: notes, sourceRef: "file:///n.txt")
        let second = try await ingester.ingest(title: "Notes", text: notes, sourceRef: "file:///n.txt")
        #expect(second.wasDeduped)
        #expect(second.itemID == first.itemID)
    }
}
