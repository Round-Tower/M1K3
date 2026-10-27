//
//  ImportSensitivity.swift
//  M1K3Import
//
//  The review screen's "unticked by default for anything sensitive" (#711): a keyword table over
//  the classes a person would not want filed without a second look — health, money, credentials,
//  where they live, how to reach them, beliefs, sexuality. It over-flags rather than under-flags
//  ("address is" in a sentence about a form flags too), and a flag only changes the default tick:
//  the user may keep anything. Words match whole tokens, phrases whole token runs.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.75 (a starting table, owed Kev's read
//  before the review screen ships).
//  Prior: none (new file).

import Foundation

public enum ImportSensitivity {
    public enum Category: String, Sendable, CaseIterable {
        case health, finance, credentials, location, contact, beliefs, sexuality
    }

    /// The policy, in the order categories are reported. Lowercase; a phrase is space-separated.
    static let table: [(Category, [String])] = [
        (.health, [
            "health", "medical", "medication", "medicine", "prescription", "prescribed", "diagnosis",
            "diagnosed", "therapy", "therapist", "doctor", "hospital", "surgery", "pregnant",
            "pregnancy", "illness", "disease", "cancer", "diabetes", "diabetic", "depression",
            "depressed", "anxiety", "adhd", "autism", "autistic", "dyslexia", "dyslexic", "allergy",
            "allergic", "insulin", "psychiatrist", "mental health",
        ]),
        (.finance, [
            "salary", "income", "debt", "debts", "loan", "mortgage", "overdraft", "bankrupt",
            "bankruptcy", "bank account", "credit card", "credit score", "savings",
        ]),
        (.credentials, [
            "password", "passwords", "passcode", "pin number", "social security", "ssn",
            "passport number", "api key",
        ]),
        (.location, ["home address", "address is", "lives at", "live at", "postcode", "eircode", "zip code"]),
        (.contact, ["phone number", "mobile number", "email address"]),
        (.beliefs, [
            "religion", "religious", "church", "mosque", "synagogue", "catholic", "protestant",
            "christian", "muslim", "jewish", "hindu", "buddhist", "atheist", "politics", "political",
            "voted", "votes",
        ]),
        (.sexuality, [
            "sexuality", "sexual", "gay", "lesbian", "bisexual", "transgender", "queer", "asexual",
        ]),
    ]

    public static func looksSensitive(_ text: String) -> Bool {
        category(of: text) != nil
    }

    /// The first class `text` touches, in table order, or nil.
    public static func category(of text: String) -> Category? {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let words = Set(tokens)
        let padded = " " + tokens.joined(separator: " ") + " "
        return table.first { _, entries in
            entries.contains { $0.contains(" ") ? padded.contains(" \($0) ") : words.contains($0) }
        }?.0
    }
}
