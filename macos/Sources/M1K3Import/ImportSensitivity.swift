//
//  ImportSensitivity.swift
//  M1K3Import
//
//  The review screen's "unticked by default for anything sensitive" (#711): a keyword table over
//  the classes a person would not want filed without a second look — health, money, credentials,
//  where they live, how to reach them, beliefs, sexuality. It over-flags rather than under-flags
//  ("address is" in a sentence about a form flags too), and a flag only changes the default tick:
//  the user may keep anything. Words match whole tokens, phrases whole token runs, after one
//  normaliser runs over the table and the text alike: a plural matches its singular
//  ("medications", "allergies", "diagnoses", "churches") and "e-mail" reads as "email".
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.75 (a starting table, owed Kev's read
//  before the review screen ships).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — plurals no longer slip past the table (`stem`, on
//  both sides), "e-mail" folds to "email", contact sits above location (an email address is contact, not where Kev
//  lives), and the dead "mental health" entry ("health" already matches) is gone. The word list is unchanged
//  otherwise and still Kev's to read. Confidence 0.8.

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
            "allergic", "insulin", "psychiatrist",
        ]),
        (.finance, [
            "salary", "income", "debt", "debts", "loan", "mortgage", "overdraft", "bankrupt",
            "bankruptcy", "bank account", "credit card", "credit score", "savings",
        ]),
        (.credentials, [
            "password", "passwords", "passcode", "pin number", "social security", "ssn",
            "passport number", "api key",
        ]),
        (.contact, ["phone number", "mobile number", "email address"]),
        (.location, ["home address", "address is", "lives at", "live at", "postcode", "eircode", "zip code"]),
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
        let tokens = normalised(text)
        let words = Set(tokens)
        let padded = " " + tokens.joined(separator: " ") + " "
        return normalisedTable.first { _, entries in
            entries.contains { $0.contains(" ") ? padded.contains(" \($0) ") : words.contains($0) }
        }?.0
    }

    /// The table run through the same normaliser as the text, once.
    private static let normalisedTable: [(Category, [String])] = table.map { category, entries in
        (category, entries.map { normalised($0).joined(separator: " ") })
    }

    /// Lowercased alphanumeric tokens, each stemmed, with "e mail" folded to "email".
    static func normalised(_ text: String) -> [String] {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map(stem)
        var folded: [String] = []
        for token in tokens {
            if token == "mail", folded.last == "e" {
                folded[folded.count - 1] = "email"
            } else {
                folded.append(token)
            }
        }
        return folded
    }

    /// A plural to its singular, crudely but identically on both sides: "allergies" → "allergy",
    /// "illnesses" → "illness", "diagnoses" → "diagnosis", "churches" → "church", "loans" → "loan".
    /// Short words and "-ss" / "-us" / "-is" endings are left alone.
    static func stem(_ token: String) -> String {
        guard token.count > 3 else { return token }
        if token.hasSuffix("ies") { return token.dropLast(3) + "y" }
        if token.hasSuffix("sses") || token.hasSuffix("xes") || token.hasSuffix("ches") || token.hasSuffix("shes") {
            return String(token.dropLast(2))
        }
        if token.hasSuffix("ses") { return token.dropLast(2) + "is" }
        if token.hasSuffix("s"), !token.hasSuffix("ss"), !token.hasSuffix("us"), !token.hasSuffix("is") {
            return String(token.dropLast())
        }
        return token
    }
}
