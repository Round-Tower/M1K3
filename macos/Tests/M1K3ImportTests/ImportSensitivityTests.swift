//
//  ImportSensitivityTests.swift
//  M1K3ImportTests
//
//  #711: the review screen shows every proposed memory, unticked by default when it touches a
//  sensitive class (health, money, credentials, beliefs, sexuality, where someone lives, how to
//  reach them). A keyword table, deliberately: it over-flags rather than under-flags, and a
//  flag only changes the default tick, never what the user may keep.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.8 (a policy table; the word list is a
//  starting point, owed Kev's read).
//  Prior: none (new file).

import Foundation
@testable import M1K3Import
import Testing

struct ImportSensitivityTests {
    @Test("each sensitive class is flagged, with its category")
    func flagsOnlyTheClasses() {
        let flagged: [(String, ImportSensitivity.Category)] = [
            ("Kev takes medication for his blood pressure", .health),
            ("Kev was diagnosed with dyslexia as a child", .health),
            ("Kev sees a therapist on Thursdays", .health),
            ("Kev's salary is 80k", .finance),
            ("Kev is paying off a car loan", .finance),
            ("Kev's wifi password is hunter2", .credentials),
            ("Kev's home address is 4 Main Street", .location),
            ("Kev lives at 12 Strand Road", .location),
            ("Kev's phone number ends in 42", .contact),
            ("Kev is a practising Catholic", .beliefs),
            ("Kev voted in the general election", .beliefs),
            ("Kev is bisexual", .sexuality),
        ]
        for (text, category) in flagged {
            #expect(ImportSensitivity.category(of: text) == category, "\(text)")
            #expect(ImportSensitivity.looksSensitive(text), "\(text)")
        }
    }

    @Test("ordinary durable facts are not flagged")
    func ordinaryFactsPass() {
        for text in [
            "Kev prefers metric units", "Kev lives in Cork", "Kev keeps bees in Kinsale",
            "Kev plays the fiddle every Sunday", "Kev is learning Irish", "Kev's sister is Aoife",
            "Kev decided to use RRF over learned fusion", "The address bar is too small",
        ] {
            #expect(!ImportSensitivity.looksSensitive(text), "\(text)")
        }
    }
}
