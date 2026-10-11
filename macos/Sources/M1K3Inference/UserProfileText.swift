//
//  UserProfileText.swift
//  M1K3Inference
//
//  The "About you" profile blob's first line is the name HelloView seeds
//  ("Name: X."). A re-run of onboarding that changes the name must rewrite
//  that line — and only that line — so the system prompt and the greeting
//  stay in sync without touching the notes the user added in Settings.
//  Pure, so the edge cases (no Name line, same name, a pasted newline) are
//  pinned by UserProfileTextTests; AppEnvironment.saveFirstRunName applies it.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.9, Prior: none (new
//  file; lifted out of AppEnvironment on the #544 bot pass).

import Foundation

public enum UserProfileText {
    /// The profile with its leading `Name: …` line rewritten for `name`, or
    /// nil when nothing should change: the profile has no `Name:` first line
    /// (the user rewrote it; leave it), the name is empty, or it already
    /// matches. The name is flattened to one line and trimmed.
    public static func rewritingName(_ name: String, in profile: String) -> String? {
        let clean = name
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        var lines = profile.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("Name: ") else { return nil }
        let line = "Name: \(clean)."
        guard first != line else { return nil }
        lines[0] = line
        return lines.joined(separator: "\n")
    }
}
