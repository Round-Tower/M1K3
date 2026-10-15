//
//  AppleFileTranscriberTests.swift
//  M1K3VoiceTests
//
//  Pins the speech-to-text eval's trailing silence: a clip that ends on speech
//  lost its last words to DictationTranscriber, so every clip is fed with a
//  second of silence after it, and the speech itself is left untouched.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.85. Prior: Unknown.

import AVFoundation
import Foundation
@testable import M1K3Voice
import Testing

struct AppleFileTranscriberTests {
    @Test("a clip gains trailing silence and keeps its audio")
    func clipGainsTrailingSilence() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: clip) }
        let tone = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        tone.frameLength = 8000
        for frame in 0 ..< 8000 {
            tone.floatChannelData?[0][frame] = 0.5
        }
        try AVAudioFile(forWriting: clip, settings: format.settings).write(from: tone)

        let padded = try AppleFileTranscriber.withTrailingSilence(clip, seconds: 1)
        defer { try? FileManager.default.removeItem(at: padded) }
        let file = try AVAudioFile(forReading: padded)
        #expect(file.length == 24000)
        let read = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24000))
        try file.read(into: read)
        let samples = try #require(read.floatChannelData?[0])
        #expect(samples[0] == 0.5)
        #expect(samples[7999] == 0.5)
        #expect(samples[8000] == 0)
        #expect(samples[23999] == 0)
    }
}
