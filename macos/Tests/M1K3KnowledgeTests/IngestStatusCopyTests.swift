//
//  IngestStatusCopyTests.swift
//  M1K3KnowledgeTests
//
//  The words the Documents banner shows while a scan is read and after it lands, shared by the Mac and
//  the iPhone so the two say the same thing.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.85. Prior: Unknown.
//

@testable import M1K3Knowledge
import Testing

struct IngestStatusCopyTests {
    @Test("progress names the page, the total and the file")
    func progress() {
        #expect(IngestStatusCopy.reading(title: "Lease", PDFTextExtractor.ScanProgress(page: 3, of: 12))
            == "Reading scanned page 3 of 12 in “Lease”…")
    }

    @Test("no scans: nothing extra to say")
    func noScans() {
        #expect(IngestStatusCopy.scanNote(.none) == nil)
    }

    @Test("scanned pages read: say how many, singular and plural")
    func scansRead() {
        #expect(IngestStatusCopy.scanNote(.init(read: 1, skipped: 0)) == "Read 1 page from scans.")
        #expect(IngestStatusCopy.scanNote(.init(read: 5, skipped: 0)) == "Read 5 pages from scans.")
    }

    @Test("past the cap: say what was skipped")
    func scansSkipped() {
        #expect(IngestStatusCopy.scanNote(.init(read: 100, skipped: 20))
            == "Read 100 pages from scans. 20 pages past the first 100 were skipped.")
        #expect(IngestStatusCopy.scanNote(.init(read: 100, skipped: 1))
            == "Read 100 pages from scans. 1 page past the first 100 was skipped.")
    }

    @Test("failed pages are counted, never folded into a false 'first N'")
    func scansFailed() {
        #expect(IngestStatusCopy.scanNote(.init(read: 97, failed: 3, skipped: 0))
            == "Read 97 pages from scans. 3 pages couldn’t be read.")
        #expect(IngestStatusCopy.scanNote(.init(read: 0, failed: 0, skipped: 4))
            == "Read 0 pages from scans. 4 pages past the first 100 were skipped.")
    }
}
