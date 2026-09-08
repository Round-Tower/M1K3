//
//  EarconSynthTests.swift
//  M1K3AvatarTests
//

import Foundation
@testable import M1K3Avatar
import Testing

struct EarconSynthTests {
    private static let synthEffects = SoundEffect.allCases.filter { $0.source == .synth }

    @Test("every synth effect renders a non-silent clip that never clips")
    func rendersNonSilentWithinRange() throws {
        for effect in Self.synthEffects {
            let samples = try #require(EarconSynth.render(effect), "\(effect) has no recipe")
            #expect(samples.count > 1000, "\(effect) is too short")
            let peak = samples.map(abs).max() ?? 0
            #expect(peak <= 1.0, "\(effect) clips")
            let rms = (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
            #expect(rms > 0.005, "\(effect) is silent")
            // Kev, on the audition: "a bit loud" — recipes sit well under full scale.
            #expect(peak < 0.75, "\(effect) peaks at \(peak)")
        }
    }

    @Test("renders are deterministic — the noise voice is seeded")
    func deterministic() {
        #expect(EarconSynth.render(.voiceEnter) == EarconSynth.render(.voiceEnter))
    }

    @Test("the bundled dial-up has no recipe")
    func dialupNotSynthesised() {
        #expect(EarconSynth.render(.dialup) == nil)
        #expect(EarconSynth.wavData(.dialup) == nil)
    }

    @Test("wav data is a 16-bit mono RIFF at 44.1k with the right byte count")
    func wavHeader() throws {
        let samples = try #require(EarconSynth.render(.stop))
        let data = try #require(EarconSynth.wavData(.stop))
        #expect(data.count == 44 + samples.count * 2)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8 ..< 12], as: UTF8.self) == "WAVE")
        let channels = data[22 ..< 24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        let rate = data[24 ..< 28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt16(littleEndian: channels) == 1)
        #expect(UInt32(littleEndian: rate) == 44100)
    }

    @Test("every clip ends in silence — no click on the tail")
    func tailsAreSilent() throws {
        for effect in Self.synthEffects {
            let samples = try #require(EarconSynth.render(effect))
            let tail = samples.suffix(64)
            #expect((tail.map(abs).max() ?? 1) < 0.02, "\(effect) ends hot")
        }
    }
}
