//
//  VoiceCharacter.swift
//  M1K3Voice
//
//  The named voice presets, so "how M1K3 sounds" is a choice with a switch rather
//  than a constant buried in a DSP chain.
//
//  ★ Why this arrived when it did (Kev, 2026-08-11): he reported M1K3 dropping
//  phonemes — "it misses the n… the very first letter in Mike". Part of that was a
//  real dictionary hole (see KokoroG2P.letterNames), but the signature chain is a
//  suspect for the rest of it: `m1k3Character` band-passes 320–3600 Hz, which is
//  telephone bandwidth, and the **nasal murmur that distinguishes /m/ from /n/ sits
//  at roughly 250–300 Hz** — below the high-pass. So the effect that gives M1K3 its
//  character may also be removing the cue that tells its own name apart from "Nike".
//  `VoiceCharacterTests` measures that energy loss rather than asserting it.
//
//  The chain was written in the AVSpeech era (June), when band-limiting a robotic
//  system voice cost little. It now sits downstream of Kokoro's 24 kHz neural PCM,
//  where it has a great deal more to throw away.
//
//  `m1k3` stays byte-identical and stays the default: changing how someone's
//  companion sounds is their call, not a side effect of a bug fix.
//
//  Signed: Kev + claude-opus-5, 2026-08-11, Confidence 0.8 (the presets are pure and
//  measured; that the 320 Hz high-pass is what Kev is HEARING is a physically
//  reasoned hypothesis his ear settles in seconds now that there's a switch).
//  Prior: VoiceEffectChain.m1k3Character (Kev + claude-sonnet-4-6, 2026-06-08).
//

import Foundation

/// How M1K3 sounds. `rawValue` is the persistence key.
public enum VoiceCharacter: String, CaseIterable, Sendable {
    /// Full-band: Kokoro's neural voice as rendered, levelled and nothing else.
    case clean
    /// The signature band-limited "transmitted" M1K3 (unchanged since 2026-07-19).
    case m1k3
    /// Further into the radio — narrower, grittier, more shimmer. Deliberate lo-fi
    /// rather than an accident of history.
    case radio

    public var displayName: String {
        switch self {
        case .clean: "Clean"
        case .m1k3: "M1K3"
        case .radio: "Radio"
        }
    }

    /// One line for a Settings footer — says what you gain and what you give up.
    public var summary: String {
        switch self {
        case .clean: "Full range, nothing added. Clearest consonants."
        case .m1k3: "The signature transmitted voice — a little radio, a little machine."
        case .radio: "Heavier lo-fi. Character over clarity."
        }
    }

    public var chain: VoiceEffectChain {
        switch self {
        case .clean:
            // Level only. Normalising to the same 0.85 as the others keeps a
            // character switch from also being a volume jump.
            VoiceEffectChain([NormalizationEffect(level: 0.85)])
        case .m1k3:
            .m1k3Character
        case .radio:
            // Narrower than a telephone, more tremolo, harder clip — and the same
            // normalise-INTO-the-clip ordering m1k3Character documents, because a
            // compressor below its threshold is an inert no-op (the 2026-07-19 bug).
            VoiceEffectChain([
                BandpassEffect(lowFrequency: 450, highFrequency: 3000),
                TremoloEffect(rate: 28, depth: 0.2),
                NormalizationEffect(level: 1.0),
                CompressionEffect(threshold: 0.45, ratio: 0.3),
                NormalizationEffect(level: 0.85),
            ])
        }
    }

    /// The default stays the signature voice: a bug fix must not silently change
    /// what someone's companion sounds like.
    public static let fallback = VoiceCharacter.m1k3

    /// Decode a persisted value, falling back rather than failing.
    public init(persisted raw: String?) {
        self = raw.flatMap(VoiceCharacter.init(rawValue:)) ?? .fallback
    }
}
