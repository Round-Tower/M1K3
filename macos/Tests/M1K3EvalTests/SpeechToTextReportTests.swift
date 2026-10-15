//
//  SpeechToTextReportTests.swift
//  M1K3EvalTests
//
//  Pins the speech-to-text eval's pure half: which files make a clip, and how
//  an arm's numbers add up (word-weighted error rate, real-time factor, failures
//  counted rather than dropped).
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.85. Prior: Unknown.

import Foundation
@testable import M1K3Eval
import Testing

struct SpeechToTextReportTests {
    @Test("a clip is audio beside its reference text, in order; strays are skipped")
    func clipsPairAudioWithReferences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, body) in [
            ("clip-02.wav", "x"), ("clip-02.txt", "second line\n"),
            ("clip-01.m4a", "x"), ("clip-01.txt", "first line"),
            ("clip-03.wav", "x"), // no reference: skipped
            ("notes.txt", "not a clip"),
        ] {
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let clips = try SpeechToTextCorpus.clips(in: dir)
        #expect(clips.map(\.id) == ["clip-01", "clip-02"])
        #expect(clips.map(\.reference) == ["first line", "second line"])
        #expect(clips[0].audio.lastPathComponent == "clip-01.m4a")
    }

    @Test("an arm weights its error rate by words and counts failed clips")
    func armAddsUp() {
        var arm = SpeechToTextArm(name: "analyzer")
        arm.add(WordErrorRate.Score(errors: 1, words: 10), audioSeconds: 4, processingSeconds: 1)
        arm.add(WordErrorRate.Score(errors: 2, words: 5), audioSeconds: 2, processingSeconds: 0.5)
        arm.fail(clip: "clip-03", reason: "assetNotInstalled")
        #expect(arm.errors == 3)
        #expect(arm.words == 15)
        #expect(abs(arm.wordErrorRate - 0.2) < 1e-9)
        #expect(abs(arm.realTimeFactor - 0.25) < 1e-9)
        #expect(arm.failures == ["clip-03: assetNotInstalled"])
    }

    @Test("the report encodes with sorted keys, so two runs diff cleanly")
    func reportEncodesSorted() throws {
        var arm = SpeechToTextArm(name: "whisper")
        arm.add(WordErrorRate.Score(errors: 0, words: 3), audioSeconds: 1, processingSeconds: 2)
        let report = SpeechToTextReport(date: "2026-10-15", clips: 1, locale: "en_IE", arms: [arm])
        let json = try String(decoding: report.encoded(), as: UTF8.self)
        #expect(json.contains("\"arms\""))
        let arms = try #require(json.range(of: "\"arms\""))
        let clips = try #require(json.range(of: "\"clips\""))
        #expect(arms.lowerBound < clips.lowerBound)
        #expect(json.contains("\"realTimeFactor\" : 2"))
    }
}
