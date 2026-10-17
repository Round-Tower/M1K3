//
//  VoiceTurnPreparer.swift
//  M1K3Voice
//
//  The last step between a voice listen and its turn, shared by the Mac and iOS
//  shells: NameRepair on the final transcript (toward KnownNames), the room
//  line through SoundContextGate, and SoundContext's song verdict logged in
//  SHADOW: a listen that reads as music without a speaker is still taken as a
//  turn, and the log says so, until live logs show the verdict never drops a
//  real turn (challenger's advice, docs/evals/2026-10-15-sound-context.md).
//
//  Repairs are logged at .notice with the words private (they're the user's
//  speech) and the score public. The room line is private too: fixed vocabulary
//  keeps it out of prompt injection, not out of what it says about a home.
//  `-voiceNameRepair NO` at launch turns NameRepair off.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-16, Confidence 0.75 (NameRepair measured on
//  one speaker; the verdict unmeasured live). Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-10-16 (after Kev's live run) — the shadow verdict caught a song twice
//  ("hands hands la", "latest news": both music, per Kev). `delivered` now logs the room line reaching the
//  brain, and `learnNames` the names' shape and a private sample (300 names hit the cap from 450 memories).
//  Review: Kev + claude-opus-5-5, 2026-10-17 — `learnNames` logs how many ordinary words NameRepair kept as locks
//  (#627), so a device without the word embedding shows up as 0. Confidence 0.8.

import Foundation
import os

@MainActor
public final class VoiceTurnPreparer {
    public struct Prepared: Equatable, Sendable {
        public let question: String
        /// For the brain's per-turn clauses only: never part of the question, so never in
        /// the chat history or memory distillation.
        public let soundClause: String?
        let heard: SoundContext?
    }

    /// The kill switch's argv key: `M1K3 -voiceNameRepair NO`.
    public static let nameRepairKey = "voiceNameRepair"

    public static func nameRepairEnabled(
        arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    ) -> Bool {
        guard let raw = arguments[nameRepairKey] as? String else { return true }
        return !["no", "0", "false", "off"].contains(raw.lowercased())
    }

    private static let sttLog = Logger(subsystem: "app.m1k3", category: "stt")
    private static let soundLog = Logger(subsystem: "app.m1k3", category: "sound-context")

    private var repair = NameRepair(names: [])
    private var gate = SoundContextGate()

    public init() {}

    public func learnNames(_ names: [String]) {
        guard Self.nameRepairEnabled() else {
            Self.sttLog.notice("name repair: off (-\(Self.nameRepairKey, privacy: .public) NO)")
            return
        }
        repair = NameRepair(names: names)
        // The count is public; a sample of the names (private) is there to judge what memory yields.
        let multiWord = names.filter { $0.contains(" ") }.count
        Self.sttLog.notice(
            "name repair: \(names.count, privacy: .public) known names (\(multiWord, privacy: .public) of several words); newest: \(names.prefix(12).joined(separator: ", "), privacy: .private)"
        )
        // 0 with ordinary words in the list means the system word embedding was missing: #627 is back.
        let locked = repair.ordinaryWordsLocked
        Self.sttLog.notice("name repair: \(locked, privacy: .public) ordinary words kept as locks, not targets")
    }

    public func prepare(_ question: String, heard: SoundContext?) -> Prepared {
        let repaired = repair.repair(question)
        for swap in repaired.repairs {
            Self.sttLog.notice(
                "name repair: \(swap.heard, privacy: .private) → \(swap.name, privacy: .private) (\(swap.score, format: .fixed(precision: 2), privacy: .public))"
            )
        }
        if heard?.verdict == .musicWithoutSpeech {
            let words = question.split(whereSeparator: \.isWhitespace).count
            Self.soundLog.notice(
                "sound context (shadow): would not take this \(words, privacy: .public)-word turn — music without a speaker (\(heard?.contextLine ?? "no line", privacy: .private)); taken anyway"
            )
        }
        return Prepared(question: repaired.text, soundClause: gate.clause(for: heard), heard: heard)
    }

    /// The prepared turn really went to the brain: its room line counts as said.
    public func delivered(_ prepared: Prepared) {
        gate.commit(prepared.heard)
        // The proof the line reached the brain (the 2026-10-16 live run couldn't tell).
        if let clause = prepared.soundClause {
            Self.soundLog.notice(
                "room line → brain (\(clause.count, privacy: .public) chars, alert: \(prepared.heard?.hasAlert == true, privacy: .public)): \(prepared.heard?.contextLine ?? "", privacy: .private)"
            )
        }
    }
}
