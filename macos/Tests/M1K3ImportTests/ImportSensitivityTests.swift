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
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the matcher's contract is pinned: plurals and
//  "e-mail" flag, an email address is contact (not location), the earlier class wins, matches are whole tokens and
//  whole runs ("Gayle" is not "gay"), and case and punctuation don't matter. Confidence 0.8.

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

    // MARK: - Review fold: the matcher

    @Test("plurals flag like their singular, and e-mail reads as email")
    func pluralsAndEmail() {
        let flagged: [(String, ImportSensitivity.Category)] = [
            ("Kev takes medications daily", .health),
            ("Kev has two prescriptions", .health),
            ("Kev has allergies to cats", .health),
            ("Kev sees doctors in Cork", .health),
            ("Kev had two diagnoses this year", .health),
            ("Kev had surgeries on his knee", .health),
            ("Kev sees two therapists", .health),
            ("Kev is repaying his loans", .finance),
            ("Kev holds two mortgages", .finance),
            ("Kev has three credit cards", .finance),
            ("Kev has two bank accounts", .finance),
            ("Kev's passwords live in a notebook", .credentials),
            ("Kev visits churches on holiday", .beliefs),
            ("Kev's friends are Muslims", .beliefs),
            ("Kev's e-mail address is on the form", .contact),
            ("Kev's email address is kev@example.com", .contact),
        ]
        for (text, category) in flagged {
            #expect(ImportSensitivity.category(of: text) == category, "\(text)")
        }
    }

    @Test("whole tokens and whole runs only: a word inside another word never flags")
    func wholeTokensOnly() {
        for text in [
            "Kev likes Gayle's cooking", "Kev flew Hindustan Aeronautics", "Kev lives atop a hill",
            "Kev's mailbox is green", "Kev's address book is full",
        ] {
            #expect(ImportSensitivity.category(of: text) == nil, "\(text)")
        }
    }

    @Test("the earlier class in the table wins; case and punctuation don't matter")
    func orderCaseAndPunctuation() {
        #expect(ImportSensitivity.category(of: "Kev's doctor's phone number is in his wallet") == .health)
        #expect(ImportSensitivity.category(of: "PASSWORD: hunter2") == .credentials)
        #expect(ImportSensitivity.category(of: "Kev... voted!") == .beliefs)
    }
}
