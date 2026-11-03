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
        #expect(IngestStatusCopy.scanNote(.init(read: 1, skipped: 0)) == "Read 1 scanned page.")
        #expect(IngestStatusCopy.scanNote(.init(read: 5, skipped: 0)) == "Read 5 scanned pages.")
    }

    @Test("past the cap: say what was skipped")
    func scansSkipped() {
        #expect(IngestStatusCopy.scanNote(.init(read: 100, skipped: 20))
            == "Read the first 100 scanned pages. 20 more were skipped.")
        #expect(IngestStatusCopy.scanNote(.init(read: 100, skipped: 1))
            == "Read the first 100 scanned pages. 1 more was skipped.")
    }
}
