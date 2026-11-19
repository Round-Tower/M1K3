//
//  ReplyLanguageBlindSetTests.swift
//  M1K3ChatTests
//
//  A ratchet on the reply-language read over the three checked-in blind sets (Resources/reply-language-blind-*.json).
//  ReplyLanguage leans on Apple's NLLanguageRecognizer, and an OS update can move its reads with no code change here
//  (the challenger's point, 2026-11-19), so this pins two things per file:
//    (a) no English-expected turn gets a wrong-language clause ("reply in Swedish" on an English question is the
//        failure that hurts), except the commented known misses below;
//    (b) the correct count never drops below what was measured when the floor was set.
//  A better read raises nothing here: when a count climbs, raise its floor in the same commit.
//
//  Re-run after every macOS / iOS update:  nice -n 15 tools/dev/tdd.sh M1K3ChatTests ReplyLanguageBlindSet
//  A failure prints every turn that went wrong. If the OS moved, fix the detector on lines written in
//  ReplyLanguageTests (never on these sets), or lower a floor with the reason in the commit.
//
//  Batches 1 and 2 are not blind any more: the detector was tuned against batch 1 on 2026-11-19 after its first run,
//  and against batch 2 in round 2 the same day (the romanised and native-question-over-English-paste fixes). Both
//  are regression sets. Batch 3 was blind when measured (2026-11-19, after round 2, no tuning against it):
//  {"total":125,"correct":101,"wrong":3,"efp":3,"noclause":5,"missed":16}. That run is the one unseen-turns claim
//  this file can back; once the detector is tuned against batch 3 it is a regression set too.
//
//  Scoring: an English-expected turn is right with an "en" read or no read (no clause is added either way); a
//  non-English turn is right only on its own language, or on no read when `unreadable_ok`. Chinese counts by base
//  language when the set says only "zh" (batch 2): a "zh-Hans" read of a Simplified line is right. The scratch
//  harness that first measured batch 2 compared raw codes and counted those reads wrong.
//
//  Signed: claude-opus-5-5, 2026-11-19, Confidence 0.8 (the floors are one machine's reads on macOS 27; the sets are
//  one author's lines). Prior: Unknown
//  Review: claude-opus-5-5, 2026-11-19 — review fold: the correct-count floors hold only from the macOS they were
//  measured on (27) upward. PR CI runs on macos-26, whose recogniser nobody has measured, so a floor from 27 is not a
//  claim about it. A newer OS still trips the floor (the tripwire this file exists for). The English false-positive
//  check runs on every OS: macOS 26 is a supported target, so a wrong clause there is a real bug, not noise.
//  Review: claude-opus-5-5, 2026-11-19 (round 2) — batch 2's floor 78 → 89 after the allowlist, Arabizi guard,
//  multi-line instruction rule and comma split; b2-op-23 leaves the known-miss list (the comma split fixes it).
//  Batch 1 holds at 137, every turn read the same as before.
//  Review: claude-opus-5-5, 2026-11-19 — blind batch 3 (125 turns) joins the ratchet at its blind-measured 101,
//  with its three English false positives (b3-pa-40, b3-op-08, b3-op-30) allowlisted as undiagnosed, not fixed.
//

import Foundation
@testable import M1K3Chat
import Testing

struct ReplyLanguageBlindSetTests {
    private struct Turn: Decodable {
        let id: String
        let text: String
        let expected: String
        // swiftlint:disable:next identifier_name
        let unreadable_ok: Bool
    }

    private struct Tally {
        var total = 0
        var correct = 0
        var wrong = 0
        var missed = 0
        var englishFalsePositives: [String] = []
        var failures: [String] = []
    }

    /// English-expected turns that may carry a wrong-language clause, each with why. Keep it short: every entry is a
    /// person asked a question in English and told, in effect, that they wrote Swedish.
    /// Empty after round 2 (2026-11-19): b2-op-23's Swedish thanks before a comma now splits from the English after it.
    /// Batch 3's three arrived with it, measured blind; each is still a bug, pinned so a fourth can't hide among them.
    private static let knownEnglishMisses: [String: String] = [
        "b3-pa-40": "blind on arrival 2026-11-19, undiagnosed", // English question over an Arabic caption, read ar
        "b3-op-08": "blind on arrival 2026-11-19, undiagnosed", // Japanese thanks line, English question; read ja
        "b3-op-30": "blind on arrival 2026-11-19, undiagnosed", // Korean thanks line, English question; read ko
    ]

    /// The correct count each file must keep (≥), measured on macOS 27 on 2026-11-19 when the floor was set.
    private static let correctFloor: [String: Int] = [
        "reply-language-blind-1": 137, // of 150; wrong 1, missed 12 (tuned against: a regression set)
        "reply-language-blind-2": 89, // of 105; wrong 2, missed 14 (tuned against in round 2: a regression set now)
        "reply-language-blind-3": 101, // of 125; wrong 8 (3 English false positives), missed 16 (blind when measured)
    ]

    /// The macOS major the floors were measured on. They bind there and on every later OS (an update that moves
    /// the reads must trip them); an earlier OS (PR CI's macos-26) has an unmeasured recogniser, so it only prints.
    private static let floorMeasuredOnMajor = 27

    /// Whether the floors bind on an OS of this major version.
    static func floorBinds(onMajor major: Int) -> Bool {
        major >= floorMeasuredOnMajor
    }

    private func load(_ name: String) throws -> [Turn] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources"),
            "\(name).json missing from M1K3ChatTests' Resources"
        )
        return try JSONDecoder().decode([Turn].self, from: Data(contentsOf: url))
    }

    /// "zh" in a set means any Chinese script; every other code is compared whole.
    private func matches(read: String, expected: String) -> Bool {
        if expected == "zh" { return read == "zh" || read.hasPrefix("zh-") }
        return read == expected
    }

    private func score(_ turns: [Turn]) -> Tally {
        var tally = Tally()
        for turn in turns {
            tally.total += 1
            let read = ReplyLanguage.detect(turn.text)
            guard let read else {
                if turn.expected == "en" || turn.unreadable_ok {
                    tally.correct += 1
                } else {
                    tally.missed += 1
                    tally.failures.append("\(turn.id) expected=\(turn.expected) read=nil")
                }
                continue
            }
            if matches(read: read, expected: turn.expected) {
                tally.correct += 1
                continue
            }
            tally.wrong += 1
            tally.failures.append("\(turn.id) expected=\(turn.expected) read=\(read)")
            if turn.expected == "en" { tally.englishFalsePositives.append(turn.id) }
        }
        return tally
    }

    @Test(arguments: ["reply-language-blind-1", "reply-language-blind-2", "reply-language-blind-3"])
    func holdsTheRatchet(file: String) throws {
        let turns = try load(file)
        #expect(!turns.isEmpty)
        let tally = score(turns)
        let summary = "\(file): \(tally.correct)/\(tally.total) correct, wrong=\(tally.wrong) "
            + "(en_fp=\(tally.englishFalsePositives.count)), missed=\(tally.missed)"
        print(summary)
        let unexpected = tally.englishFalsePositives.filter { Self.knownEnglishMisses[$0] == nil }
        let failures = tally.failures.joined(separator: "\n")
        #expect(
            unexpected.isEmpty,
            "English turns given a wrong-language clause: \(unexpected). \(summary)\n\(failures)"
        )
        let floor = try #require(Self.correctFloor[file])
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard Self.floorBinds(onMajor: major) else {
            print("\(file): floor \(floor) measured on macOS \(Self.floorMeasuredOnMajor), not enforced on \(major)")
            return
        }
        #expect(
            tally.correct >= floor,
            "correct fell below the floor \(floor). \(summary)\n\(failures)"
        )
    }

    @Test func floorBindsFromTheMeasuredOSUpward() {
        #expect(!Self.floorBinds(onMajor: 26)) // PR CI's macos-26: unmeasured
        #expect(Self.floorBinds(onMajor: 27))
        #expect(Self.floorBinds(onMajor: 28)) // an OS update must still trip the ratchet
    }
}
