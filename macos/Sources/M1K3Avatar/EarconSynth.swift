//
//  EarconSynth.swift
//  M1K3Avatar
//
//  M1K3's sound effects, synthesised in code from ONE small instrument so the
//  whole vocabulary shares a timbre — the phosphor identity in sound: square /
//  triangle cores, a touch of bit-crush, pentatonic pitches around A. No
//  samples to keep in tune, no licences to trace; retune a sound by editing
//  its recipe. Promoted from scratch/jam-2026-09-08-synth (Kev: "kinda love
//  em — a bit loud though"; the gains here sit ~40% under the audition).
//
//  Pure and deterministic (the noise voice runs a seeded LCG), so a render is
//  test-pinned byte for byte and the AVAudioPlayer pool can build once at init.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.7 (the instrument
//  is the keeper; every recipe is a first draft for Kev's ear). Prior: Unknown.
//

import Foundation

public enum EarconSynth {
    public static let sampleRate = 44100.0

    enum Wave { case sine, square, triangle, saw, noise }

    /// One voice in a recipe: a waveform under an ADSR, optionally gliding in
    /// pitch, with vibrato and a bit-crush depth.
    struct Voice {
        var wave: Wave = .square
        var startHz: Double
        var endHz: Double? = nil
        var glideCurve = 1.0 // 1 linear, >1 eases out, <1 eases in
        var duration: Double // gate length, before the release
        var attack = 0.005
        var decay = 0.05
        var sustain = 0.6
        var release = 0.08
        var gain = 0.3
        var crushBits: Int? = nil
        var startAt = 0.0
        var vibratoHz = 0.0
        var vibratoDepth = 0.0 // semitones
    }

    struct Recipe {
        let voices: [Voice]
        let length: Double
    }

    // MARK: - The house key: A pentatonic

    static let a3 = 220.0, e4 = 329.6276, a4 = 440.0
    static let cs5 = semitone(a4, 4), e5 = semitone(a4, 7), fs5 = semitone(a4, 9), a5 = semitone(a4, 12)

    static func semitone(_ hz: Double, _ n: Double) -> Double {
        hz * pow(2, n / 12)
    }

    /// The vocabulary. Each `SoundEffect` with a `.synth` source has exactly
    /// one recipe here (pinned by tests).
    static func recipe(for effect: SoundEffect) -> Recipe? {
        switch effect {
        case .listenStart: // the mic opens — a rising two-note, an eyebrow going up
            Recipe(voices: [
                Voice(startHz: e5, duration: 0.06, gain: 0.2, crushBits: 6),
                Voice(startHz: a5, duration: 0.09, release: 0.12, gain: 0.2, crushBits: 6, startAt: 0.07),
            ], length: 0.4)
        case .endpointHeard: // you finished speaking, M1K3 got it — one soft tick down
            Recipe(voices: [
                Voice(wave: .triangle, startHz: a5, endHz: e5, glideCurve: 0.6, duration: 0.05, release: 0.06, gain: 0.24),
            ], length: 0.25)
        case .thinkingTick: // a heartbeat while it thinks — barely there
            Recipe(voices: [
                Voice(wave: .sine, startHz: a3, duration: 0.03, release: 0.05, gain: 0.15),
                Voice(wave: .sine, startHz: a3, duration: 0.03, release: 0.05, gain: 0.11, startAt: 0.14),
            ], length: 0.5)
        case .toolCall: // M1K3 reaches for a tool — a quick mechanical blip-blip, crushed
            Recipe(voices: [
                Voice(startHz: cs5, duration: 0.03, release: 0.02, gain: 0.18, crushBits: 4),
                Voice(startHz: fs5, duration: 0.03, release: 0.03, gain: 0.18, crushBits: 4, startAt: 0.05),
            ], length: 0.3)
        case .answerLanded: // done — a settled three-note resolve to the tonic
            Recipe(voices: [
                Voice(wave: .triangle, startHz: e5, duration: 0.07, gain: 0.2),
                Voice(wave: .triangle, startHz: cs5, duration: 0.07, gain: 0.2, startAt: 0.08),
                Voice(wave: .triangle, startHz: a4, duration: 0.14, release: 0.2, gain: 0.24, startAt: 0.16),
                Voice(wave: .sine, startHz: a3, duration: 0.14, release: 0.2, gain: 0.12, startAt: 0.16),
            ], length: 0.7)
        case .stop: // the user cut it short — a short falling slide, no drama
            Recipe(voices: [
                Voice(startHz: e5, endHz: a3, glideCurve: 1.6, duration: 0.12, release: 0.05, gain: 0.2, crushBits: 5),
            ], length: 0.3)
        case .save: // a memory stored — the coin, in our key: two rising bright hits
            Recipe(voices: [
                Voice(startHz: fs5, duration: 0.05, release: 0.04, gain: 0.18, crushBits: 6),
                Voice(startHz: a5, duration: 0.09, release: 0.25, gain: 0.18, crushBits: 6, startAt: 0.06),
                Voice(wave: .sine, startHz: semitone(a5, 12), duration: 0.09, release: 0.25, gain: 0.07, startAt: 0.06),
            ], length: 0.6)
        case .error: // something failed — a flat minor-second buzz, brief, never a klaxon
            Recipe(voices: [
                Voice(wave: .saw, startHz: e4, duration: 0.14, release: 0.08, gain: 0.18, crushBits: 5),
                Voice(wave: .saw, startHz: semitone(e4, 1), duration: 0.14, release: 0.08, gain: 0.18, crushBits: 5),
            ], length: 0.4)
        case .voiceEnter: // M1K3 materialises — a rising sweep, vibrato blooming at the top
            Recipe(voices: [
                Voice(wave: .triangle, startHz: a3, endHz: a5, glideCurve: 0.5, duration: 0.35, release: 0.3, gain: 0.2,
                      vibratoHz: 6, vibratoDepth: 0.3),
                Voice(wave: .noise, startHz: 0, duration: 0.35, attack: 0.2, decay: 0.1, sustain: 0.2, release: 0.3,
                      gain: 0.03, crushBits: 4),
            ], length: 0.9)
        case .voiceExit: // and dematerialises — the sweep mirrored, down
            Recipe(voices: [
                Voice(wave: .triangle, startHz: a5, endHz: a3, glideCurve: 1.8, duration: 0.3, release: 0.25, gain: 0.18,
                      vibratoHz: 6, vibratoDepth: 0.3),
            ], length: 0.7)
        case .soundMark: // the signature — M-1-K-3 as four notes: A, up to E, down to C#, home to A
            Recipe(voices: [
                Voice(startHz: a4, duration: 0.1, gain: 0.18, crushBits: 6),
                Voice(startHz: e5, duration: 0.1, gain: 0.18, crushBits: 6, startAt: 0.12),
                Voice(startHz: cs5, duration: 0.1, gain: 0.18, crushBits: 6, startAt: 0.24),
                Voice(wave: .triangle, startHz: a4, duration: 0.25, release: 0.4, gain: 0.24, startAt: 0.36),
                Voice(wave: .sine, startHz: a3, duration: 0.25, release: 0.4, gain: 0.12, startAt: 0.36),
            ], length: 1.1)
        case .dialup: // bundled — a real modem handshake, minutes of texture no recipe replaces
            nil
        }
    }

    // MARK: - Rendering

    /// Mono Float32 samples in −1…1, or nil for a bundled (non-synth) effect.
    public static func render(_ effect: SoundEffect) -> [Float]? {
        recipe(for: effect).map(render)
    }

    static func render(_ recipe: Recipe) -> [Float] {
        let n = Int(recipe.length * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var noise = LCG(seed: 0x4D31_4B33) // "M1K3" — deterministic renders
        for v in recipe.voices {
            var phase = 0.0
            let total = v.duration + v.release
            let start = Int(v.startAt * sampleRate)
            for i in 0 ..< Int(total * sampleRate) {
                guard start + i < n else { break }
                let t = Double(i) / sampleRate
                var hz = v.startHz
                if let end = v.endHz {
                    let p = min(t / v.duration, 1)
                    hz = v.startHz + (end - v.startHz) * pow(p, v.glideCurve)
                }
                if v.vibratoHz > 0 {
                    hz = semitone(hz, sin(2 * .pi * v.vibratoHz * t) * v.vibratoDepth)
                }
                phase += hz / sampleRate
                phase -= floor(phase)
                var s: Double
                switch v.wave {
                case .sine: s = sin(2 * .pi * phase)
                case .square: s = phase < 0.5 ? 1 : -1
                case .triangle: s = 4 * abs(phase - 0.5) - 1
                case .saw: s = 2 * phase - 1
                case .noise: s = noise.next()
                }
                s *= envelope(v, at: t) * v.gain
                if let bits = v.crushBits {
                    let steps = pow(2.0, Double(bits))
                    s = (s * steps).rounded() / steps
                }
                out[start + i] += Float(s)
            }
        }
        return out.map { tanh($0 * 1.2) } // soft clip — nothing here can exceed ±1
    }

    /// Attack → decay → sustain while the gate is open, then a linear release
    /// FROM WHATEVER LEVEL THE GATE REACHED — a short note whose gate closes
    /// mid-attack or mid-decay releases from there, so the envelope is
    /// continuous for every recipe (review 1 on #251: the old shape released
    /// from `sustain`, a jump for any voice whose attack+decay outlived its
    /// duration, and the loop could end before the release branch ran).
    static func envelope(_ v: Voice, at t: Double) -> Double {
        func gated(_ t: Double) -> Double {
            if t < v.attack { return t / v.attack }
            if t < v.attack + v.decay { return 1 - (1 - v.sustain) * ((t - v.attack) / v.decay) }
            return v.sustain
        }
        guard t >= v.duration else { return gated(t) }
        guard v.release > 0 else { return 0 }
        return gated(v.duration) * max(0, 1 - (t - v.duration) / v.release)
    }

    /// The render as a 16-bit mono RIFF/WAVE blob — what `AVAudioPlayer(data:)` eats.
    public static func wavData(_ effect: SoundEffect) -> Data? {
        render(effect).map(wavData)
    }

    static func wavData(_ samples: [Float]) -> Data {
        var data = Data()
        func le32(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        func le16(_ v: UInt16) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + pcm.count * 2))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        le32(16); le16(1); le16(1); le32(UInt32(sampleRate)); le32(UInt32(sampleRate) * 2); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(UInt32(pcm.count * 2))
        for s in pcm {
            le16(UInt16(bitPattern: s))
        }
        return data
    }

    /// Deterministic noise. A seeded linear congruential generator — the
    /// system RNG would make every render (and every pinned test) different.
    struct LCG {
        var state: UInt64
        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }
}
