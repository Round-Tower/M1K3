//
//  AppleBufferTranscriberTests.swift
//  M1K3VoiceTests
//
//  The pure half of the polish pass's engine: the utterance's samples into one buffer in the
//  analyzer's format (`analyzerBuffer`). The Speech calls around it are verify-by-launch and the
//  eval's "polish" arm.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-16, Confidence 0.8, Prior: Unknown (new file).

import AVFoundation
import Foundation
@testable import M1K3Voice
import Testing

struct AppleBufferTranscriberTests {
    private func sine(seconds: Double, rate: Double, hertz: Double = 440, amplitude: Float = 0.5) -> [Float] {
        (0 ..< Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * hertz * Double($0) / rate)) }
    }

    private func format(_ rate: Double, _ common: AVAudioCommonFormat = .pcmFormatInt16) throws -> AVAudioFormat {
        try #require(AVAudioFormat(commonFormat: common, sampleRate: rate, channels: 1, interleaved: false))
    }

    private func rms(_ buffer: AVAudioPCMBuffer) throws -> Double {
        let count = Int(buffer.frameLength)
        if let ints = buffer.int16ChannelData {
            let sum = (0 ..< count).reduce(0.0) { $0 + pow(Double(ints[0][$1]) / 32768, 2) }
            return (sum / Double(count)).squareRoot()
        }
        let floats = try #require(buffer.floatChannelData)
        let sum = (0 ..< count).reduce(0.0) { $0 + pow(Double(floats[0][$1]), 2) }
        return (sum / Double(count)).squareRoot()
    }

    @Test("48 kHz and 44.1 kHz convert to the analyzer's 16 kHz with the length and level kept",
          arguments: [48000.0, 44100.0])
    func downsamples(rate: Double) throws {
        let samples = sine(seconds: 2, rate: rate)
        let buffer = try AppleBufferTranscriber.analyzerBuffer(samples, sampleRate: rate, format: format(16000))
        #expect(buffer.format.sampleRate == 16000)
        #expect(abs(Double(buffer.frameLength) - 32000) <= 32000 * 0.02)
        // A 0.5-amplitude sine has RMS 0.5 / sqrt(2).
        #expect(try abs(rms(buffer) - 0.5 / 2.0.squareRoot()) < 0.03)
    }

    @Test("the same rate in the analyzer's own sample type converts without changing length")
    func sameRateOtherType() throws {
        let samples = sine(seconds: 1, rate: 16000)
        let buffer = try AppleBufferTranscriber.analyzerBuffer(samples, sampleRate: 16000, format: format(16000))
        #expect(buffer.frameLength == 16000)
        #expect(try abs(rms(buffer) - 0.5 / 2.0.squareRoot()) < 0.01)
    }

    @Test("the same rate and type passes the samples straight through")
    func sameFormat() throws {
        let samples = sine(seconds: 1, rate: 16000)
        let buffer = try AppleBufferTranscriber.analyzerBuffer(
            samples, sampleRate: 16000, format: format(16000, .pcmFormatFloat32)
        )
        #expect(buffer.frameLength == 16000)
        let data = try #require(buffer.floatChannelData)
        #expect(data[0][100] == samples[100])
    }

    @Test("an empty utterance is unusable, not a zero-length buffer for the analyzer")
    func empty() throws {
        #expect(throws: AppleBufferTranscriber.Failure.unusableAudio) {
            try AppleBufferTranscriber.analyzerBuffer([], sampleRate: 16000, format: format(16000))
        }
    }

    @Test("a sine survives a 48 kHz to 16 kHz round trip by frequency, not just by length")
    func roundTrip() throws {
        let samples = sine(seconds: 1, rate: 48000, hertz: 1000)
        let buffer = try AppleBufferTranscriber.analyzerBuffer(
            samples, sampleRate: 48000, format: format(16000, .pcmFormatFloat32)
        )
        let data = try #require(buffer.floatChannelData)[0]
        // Count rising zero crossings in the middle half, clear of the converter's edges: 1 kHz is
        // 1000 per second, so half a second holds about 500.
        let count = Int(buffer.frameLength)
        var crossings = 0
        for index in (count / 4 + 1) ..< (3 * count / 4) where data[index - 1] < 0 && data[index] >= 0 {
            crossings += 1
        }
        #expect(abs(crossings - 500) <= 10)
    }
}
