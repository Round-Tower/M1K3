//
//  IOSAgeWiringScanTests.swift
//  M1K3ChatTests
//
//  The review notes promise a code gate under 16 (no web tools) and an age-appropriate tone for
//  minors. The policy was tested and the Mac wired; the iPhone's responder read neither. The
//  shell has no test target, so its wiring is read off source.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-22, Confidence 0.8 (source scan; device try owed).
//  Prior: none (new file).
//

import Foundation
import Testing

struct IOSAgeWiringScanTests {
    @Test("the iPhone's palette, privacy facts and prompt all read the age band")
    func iPhoneReadsTheBand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("M1K3iOSApp/AppCore.swift"), encoding: .utf8)
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let palette = "let webAllowed = Self.webToolsAllowedNow()"
        let facts = "webSearch: Self.webToolsAllowedNow()"
        let rule = "webSearchAllowed() && agePolicy().webToolsAllowed"
        let clause = "ageClauseProvider: { Self.agePolicy().promptClause }"
        #expect(code.contains(palette))
        #expect(code.contains(facts))
        #expect(code.contains(rule))
        #expect(code.contains(clause))
        let look = try String(contentsOf: root.appendingPathComponent("M1K3iOSApp/AppCore+Look.swift"), encoding: .utf8)
        let switchOnly = "Self.webSearchAllowed()"
        #expect(!look.contains(switchOnly))
    }
}
