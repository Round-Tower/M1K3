//
//  IngestStatusCopy.swift
//  M1K3Knowledge
//
//  The Documents banner's words for a scanned PDF: progress while its pages are read, and a note on
//  how many were read (or skipped past the cap) once it lands. Shared by the Mac and the iPhone.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.85. Prior: Unknown.
//

import Foundation

public enum IngestStatusCopy {
    public static func reading(title: String, _ step: PDFTextExtractor.ScanProgress) -> String {
        "Reading scanned page \(step.page) of \(step.of) in “\(title)”…"
    }

    /// A sentence to append to the "Indexed" line, or nil when no page was a scan.
    public static func scanNote(_ scans: PDFTextExtractor.ScanReport) -> String? {
        guard scans.read > 0 || scans.skipped > 0 else { return nil }
        guard scans.skipped > 0 else {
            return "Read \(scans.read) scanned \(scans.read == 1 ? "page" : "pages")."
        }
        let more = scans.skipped == 1 ? "1 more was skipped." : "\(scans.skipped) more were skipped."
        return "Read the first \(scans.read) scanned pages. \(more)"
    }
}
