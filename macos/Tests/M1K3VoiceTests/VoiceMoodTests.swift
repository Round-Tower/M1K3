//
//  VoiceMoodTests.swift
//  M1K3VoiceTests
//
//  #576 §1: the `speak` tool's emotion moved only the face. A mood now carries
//  into the voice as a small change of pace and pitch: big enough to hear, small
//  enough that a neural or system voice never sounds broken. Neutral, which
//  every caller without an emotion gets, is exactly today's utterance.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.85 (the table is pure
//  and pinned; how each mood SOUNDS is verify-by-launch). Prior: none (new file).
//

import Foundation
@testable import M1K3Voice
import Testing

struct VoiceMoodTests {
    @Test("neutral is exactly today's utterance, so every caller without an emotion is unchanged")
    func neutralIsToday() {
        #expect(SpeechUtterance(text: "hi", mood: .neutral) == SpeechUtterance(text: "hi"))
        #expect(SpeechUtterance(text: "hi").speedMultiplier == 1)
    }

    @Test("every emotion the speak tool and the avatar know has a mood, read the same way")
    func namesMatchTheAvatar() throws {
        let tool = ["happy", "sad", "angry", "surprised", "love", "thinking", "excited", "sleepy", "neutral"]
        #expect(Set(VoiceMood.allCases.map(\.rawValue)) == Set(tool))
        // AvatarEmotion lives in M1K3Avatar, which this target does not link: read its cases.
        let avatar = try String(
            contentsOf: Self.macos.appendingPathComponent("Sources/M1K3Avatar/AvatarEmotion.swift"), encoding: .utf8
        )
        let cases = avatar.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { return nil }
            return String(trimmed.dropFirst(5))
        }
        #expect(Set(cases) == Set(tool), "a new AvatarEmotion needs a VoiceMood too")
        #expect(VoiceMood("EXCITED") == .excited)
        #expect(VoiceMood("grumpy") == .neutral)
        #expect(VoiceMood(nil) == .neutral)
    }

    @Test("every mood stays subtle: a voice pushed further sounds broken, not moody")
    func staysSubtle() {
        for mood in VoiceMood.allCases {
            #expect((0.85 ... 1.15).contains(mood.prosody.speed), "\(mood) speed")
            #expect((0.9 ... 1.12).contains(mood.prosody.pitch), "\(mood) pitch")
        }
    }

    @Test("the moods point the way they should")
    func directions() {
        let speed = { (mood: VoiceMood) in mood.prosody.speed }
        let pitch = { (mood: VoiceMood) in mood.prosody.pitch }
        #expect(speed(.excited) > speed(.happy) && speed(.happy) > speed(.neutral))
        #expect(speed(.sleepy) < speed(.sad) && speed(.sad) < speed(.neutral))
        #expect(pitch(.surprised) > pitch(.neutral) && pitch(.sad) < pitch(.neutral))
        #expect(speed(.thinking) < speed(.neutral))
    }

    @Test("the utterance carries the mood: Apple voices read rate and pitch, Kokoro the speed")
    func utteranceCarriesIt() {
        for mood in VoiceMood.allCases {
            let utterance = SpeechUtterance(text: "x", mood: mood)
            #expect(abs(utterance.speedMultiplier - mood.prosody.speed) < 0.0001, "\(mood)")
            #expect(abs(utterance.pitch - mood.prosody.pitch) < 0.0001, "\(mood)")
        }
    }

    @Test("the Mac shell hands the speak tool's emotion to the voice, not only the face")
    func wiredInTheShell() throws {
        let voice = try Self.code("M1K3App/AppEnvironment+VoiceMode.swift")
        #expect(voice.contains("SpeechUtterance(text: spoken, mood: mood)"))
        #expect(voice.contains("mood: VoiceMood = .neutral"), "every caller without an emotion stays neutral")
        let intelligence = try Self.code("M1K3App/AppEnvironment+Intelligence.swift")
        #expect(intelligence.contains("let mood = VoiceMood(emotion)"), "M1K3's own speak path")
        #expect(
            intelligence.components(separatedBy: "narrator: narrator, mood: mood)").count - 1 == 2,
            "both the waited and the fire-and-forget branch"
        )
        #expect(intelligence.contains("mood: VoiceMood(request.emotion)"), "a visitor's queued line")
    }

    /// A source file without its comment lines, so a Review line that quotes the
    /// code cannot satisfy a scan on its own.
    private static func code(_ relative: String) throws -> String {
        try String(contentsOf: macos.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static let macos = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
