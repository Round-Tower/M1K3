//
//  VoiceCharacterTests.swift
//  M1K3VoiceTests
//
//  Measures the presets on synthetic tone, so the claim behind them is evidence
//  rather than an assertion in a comment: the signature chain's 320 Hz high-pass
//  removes the band where the nasal murmur of /m/ and /n/ lives (~250–300 Hz),
//  which is a candidate explanation for Kev hearing M1K3's own name lose its "M".
//
//  Signed: Kev + claude-opus-5, 2026-08-11, Confidence 0.9 (pure DSP over generated
//  sine tone — deterministic, no audio hardware). Prior: Unknown.
//

import Foundation
import M1K3Voice
import Testing

struct VoiceCharacterTests {
    private let sampleRate = 24000.0 // Kokoro's rate

    /// A pure tone at `frequency`, one second, amplitude 0.5.
    private func tone(_ frequency: Double) -> [Float] {
        (0 ..< Int(sampleRate)).map { index in
            Float(0.5 * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Two tones mixed — a stand-in for the low (nasal) and mid (vowel) bands of a
    /// real voice.
    private func twoTone(_ low: Double, _ high: Double) -> [Float] {
        let a = tone(low), b = tone(high)
        return zip(a, b).map { ($0 + $1) / 2 }
    }

    /// Magnitude at one frequency (Goertzel) — a single DFT bin, no FFT dependency.
    private func magnitude(of samples: [Float], at frequency: Double) -> Float {
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var s1 = 0.0, s2 = 0.0
        for sample in samples {
            let s0 = Double(sample) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        return Float((s1 * s1 + s2 * s2 - coefficient * s1 * s2).squareRoot() / Double(samples.count))
    }

    /// ★ Measured as a RATIO of low-band to mid-band energy, on purpose.
    ///
    /// The first cut of this test compared absolute RMS of a single 270 Hz tone and
    /// FALSIFIED the hypothesis — because both chains end in a normalisation, which
    /// re-amplifies whatever survives the filter, so a lone tone comes out at the
    /// same level either way. The measurement was wrong, not the claim: on real
    /// speech, normalisation is driven by the loud mid band, so the quiet nasal band
    /// is attenuated RELATIVE to everything else. A ratio is immune to gain.
    @Test("the signature chain throws away the nasal band relative to the vowel band")
    func nasalBandSurvivesOnlyOnClean() {
        // 270 Hz is inside the nasal murmur that separates /m/ from /n/ and below
        // m1k3Character's 320 Hz high-pass; 1 kHz stands in for the vowel.
        let voice = twoTone(270, 1000)
        func nasalToVowel(_ character: VoiceCharacter) -> Float {
            let out = character.chain.process(voice, sampleRate: sampleRate)
            return magnitude(of: out, at: 270) / magnitude(of: out, at: 1000)
        }
        let clean = nasalToVowel(.clean)
        let signature = nasalToVowel(.m1k3)
        // ★ MEASURED: clean 1.00, signature 0.554 — the nasal band comes through
        // about 5 dB down relative to the vowel. So the hypothesis holds in
        // DIRECTION but is modest in size: 5 dB colours the voice, it does not
        // delete a consonant. The missing "M" in "M1K3" was the dictionary hole
        // (KokoroG2P.letterNames), and this chain is at most a contributor to a
        // muffled, boxy character. Named honestly here so nobody later cites this
        // test as having explained the dropped phoneme.
        //
        // The bandpass slope is gentle — 270 Hz against a 320 Hz corner loses only
        // ~5 dB — so anything genuinely low (a male voice's fundamental near
        // 100–150 Hz) is hit considerably harder than this fixture shows.
        #expect(clean > signature * 1.4,
                "nasal:vowel ratio — clean \(clean) vs m1k3 \(signature)")
    }

    @Test("a mid-band vowel tone survives every preset — none of them is broken")
    func vowelBandSurvivesEverywhere() {
        // 1 kHz sits inside every preset's passband; if a preset kills this, it's
        // not a character, it's a fault.
        let vowel = tone(1000)
        for character in VoiceCharacter.allCases {
            let level = rms(character.chain.process(vowel, sampleRate: sampleRate))
            #expect(level > 0.05, "\(character.rawValue) silenced a 1 kHz tone (\(level))")
        }
    }

    @Test("every preset lands in the same headroom, so switching isn't a volume jump")
    func presetsShareHeadroom() {
        let vowel = tone(1000)
        for character in VoiceCharacter.allCases {
            let peak = character.chain.process(vowel, sampleRate: sampleRate)
                .map(abs).max() ?? 0
            #expect(peak <= 1.0, "\(character.rawValue) clips at \(peak)")
            #expect(peak > 0.5, "\(character.rawValue) is unusably quiet at \(peak)")
        }
    }

    @Test("radio is narrower than the signature voice, and clean is the widest")
    func bandwidthOrdering() {
        // Same ratio method as above (absolute levels are normalised flat). 400 Hz
        // passes m1k3's 320 Hz corner and sits under radio's 450 Hz corner.
        let voice = twoTone(400, 1000)
        func lowToMid(_ character: VoiceCharacter) -> Float {
            let out = character.chain.process(voice, sampleRate: sampleRate)
            return magnitude(of: out, at: 400) / magnitude(of: out, at: 1000)
        }
        #expect(lowToMid(.radio) < lowToMid(.m1k3))
        #expect(lowToMid(.m1k3) < lowToMid(.clean))
    }

    @Test("the default is the voice people already have")
    func defaultIsUnchanged() {
        #expect(VoiceCharacter.fallback == .m1k3)
        #expect(VoiceCharacter(persisted: nil) == .m1k3)
        #expect(VoiceCharacter(persisted: "nonsense") == .m1k3)
        #expect(VoiceCharacter(persisted: "clean") == .clean)
    }
}
