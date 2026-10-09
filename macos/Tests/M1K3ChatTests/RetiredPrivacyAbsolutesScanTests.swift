//
//  RetiredPrivacyAbsolutesScanTests.swift
//  M1K3ChatTests
//
//  The copy pin for #479 / PR #527: the privacy absolutes retired because they were
//  false ("nothing leaves this Mac" — web search is on by default; "no cloud" — the
//  App Store build carries an opt-in Private Cloud Compute brain) must not creep back
//  into anything that ships. The wording is spread across the Hello card, the
//  staged-switch pitch, the TCC usage strings and the store copy, and only the search
//  provider's name was pinned before this scan. Source-scan in the style of
//  AgeRangeRequestFailureTests.shellsNameNoAppleCases.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.85 (a line heuristic: a
//  phrase split across two source lines slips past; the four phrases are the ones App
//  Review and the PR #527 review named, not every possible absolute). Prior: none.
//

import Foundation
import Testing

struct RetiredPrivacyAbsolutesScanTests {
    /// The retired absolutes, matched case-insensitively. Each one WAS shipped copy and
    /// each one is false for the app that ships:
    /// - "nothing leaves this Mac" / "Nothing leaves your Mac": web search (on by default)
    ///   carries the query, and calendar or location words, off the Mac; the App Store
    ///   build's PCC brain sends a message when picked.
    /// - "everything stays on this Mac": same two exits.
    /// - "no cloud, no account": the "no account" half is true; "no cloud" is not on the
    ///   App Store lane. The pair is listed as a unit because that was the shipped phrase.
    /// Scoped claims stay allowed — "The audio never leaves your Mac" (transcription is
    /// on-device) and "stays on this Mac, except that a web search … can carry it".
    static let retiredAbsolutes = [
        "nothing leaves this mac",
        "nothing leaves your mac",
        "everything stays on this mac",
        "no cloud, no account",
    ]

    /// `macos/`, the package root, resolved from this file (Tests/M1K3ChatTests/<file>).
    static var macosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Lines that ship: every line of a shell file except `//` comments (the MurphySig
    /// review lines quote the retired phrase to record its retirement), the usage strings
    /// in project.yml (its comments explain the same retirement), and the whole of each
    /// en-US store-copy file.
    static func shippedLines(in url: URL) throws -> [(number: Int, text: String)] {
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        return lines.enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            switch url.pathExtension {
            case "swift":
                return trimmed.hasPrefix("//") ? nil : (index + 1, line)
            case "yml":
                return trimmed.contains("UsageDescription:") ? (index + 1, line) : nil
            default:
                return (index + 1, line)
            }
        }
    }

    /// The scanned surfaces: both shells, the usage strings and the en-US store copy.
    static func shippedFiles() throws -> [URL] {
        let root = macosRoot
        let fm = FileManager.default
        var files: [URL] = [root.appendingPathComponent("project.yml")]
        for shell in ["M1K3App", "M1K3iOSApp"] {
            let dir = root.appendingPathComponent(shell)
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where ["swift", "xcprivacy", "strings"].contains(url.pathExtension) {
                files.append(url)
            }
        }
        let fastlane = root.appendingPathComponent("fastlane")
        for folder in try fm.contentsOfDirectory(atPath: fastlane.path) where folder.hasPrefix("metadata_") {
            let enUS = fastlane.appendingPathComponent(folder).appendingPathComponent("en-US")
            guard let walker = fm.enumerator(at: enUS, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "txt" {
                files.append(url)
            }
        }
        return files
    }

    /// Every (file, line) that carries a retired absolute.
    static func hits(in files: [URL]) throws -> [String] {
        var hits: [String] = []
        for file in files {
            for (number, line) in try shippedLines(in: file) {
                let lowered = line.lowercased()
                for phrase in retiredAbsolutes where lowered.contains(phrase) {
                    hits.append("\(file.path):\(number): \"\(phrase)\"")
                }
            }
        }
        return hits
    }

    @Test("the scan covers the shells, the usage strings and the en-US store copy")
    func scanCoversTheSurfaces() throws {
        let paths = try Self.shippedFiles().map(\.path)
        #expect(paths.contains { $0.hasSuffix("M1K3App/HelloView.swift") })
        #expect(paths.contains { $0.hasSuffix("M1K3App/PrivacyInfo.xcprivacy") })
        #expect(paths.contains { $0.hasSuffix("M1K3iOSApp/SettingsScreen.swift") })
        #expect(paths.contains { $0.hasSuffix("macos/project.yml") })
        #expect(paths.contains { $0.hasSuffix("metadata_mac/en-US/description.txt") })
        #expect(paths.contains { $0.hasSuffix("metadata_ios/en-US/description.txt") })
    }

    @Test("a seeded absolute is caught, in any case, and a review comment is not")
    func seededAbsoluteIsCaught() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retired-absolutes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let swift = dir.appendingPathComponent("Seeded.swift")
        try """
        //  Review: the card said "nothing leaves this Mac" — retired.
        let line = "Runs on this Mac. NOTHING LEAVES THIS MAC."
        """.write(to: swift, atomically: true, encoding: .utf8)
        let yml = dir.appendingPathComponent("project.yml")
        try """
        # Nothing leaves your Mac — the comment is allowed.
        NSCalendarsFullAccessUsageDescription: "Reads events. Nothing leaves your Mac."
        """.write(to: yml, atomically: true, encoding: .utf8)
        let copy = dir.appendingPathComponent("description.txt")
        try "No cloud, no account, no telemetry.".write(to: copy, atomically: true, encoding: .utf8)

        let hits = try Self.hits(in: [swift, yml, copy])
        #expect(hits.count == 3, "\(hits)")
        #expect(hits.contains { $0.hasSuffix("Seeded.swift:2: \"nothing leaves this mac\"") })
        #expect(hits.contains { $0.hasSuffix("project.yml:2: \"nothing leaves your mac\"") })
        #expect(hits.contains { $0.hasSuffix("description.txt:1: \"no cloud, no account\"") })
    }

    @Test("nothing that ships carries a retired privacy absolute")
    func treeIsClean() throws {
        for hit in try Self.hits(in: Self.shippedFiles()) {
            Issue.record("retired privacy absolute: \(hit)")
        }
    }
}
