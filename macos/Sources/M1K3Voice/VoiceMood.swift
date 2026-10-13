//
//  VoiceMood.swift
//  M1K3Voice
//
//  How a line should sound (#576 §1). The MCP `speak` tool has always taken an
//  emotion, but only the avatar's face followed it; the voice was identical for
//  every mood. A mood is now a small change of pace and pitch carried on the
//  utterance. Apple voices read both (`rate`, `pitchMultiplier`); Kokoro has no
//  pitch control, so it takes the pace alone (`speedMultiplier`).
//
//  The names are AvatarEmotion's, so one emotion drives face and voice
//  (VoiceMoodTests pins the two lists together). Neutral is exactly the default
//  utterance: every caller that passes no emotion sounds as it did.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.8 (the table is pure
//  and pinned; whether each mood reads as itself is verify-by-launch, by ear).
//  Prior: none (new file).
//

import Foundation

public enum VoiceMood: String, CaseIterable, Sendable {
    case neutral
    case happy
    case excited
    case surprised
    case love
    case thinking
    case sad
    case sleepy
    case angry

    /// The speak tool's emotion, read the way AvatarEmotion reads it: any case,
    /// and anything unknown (or nothing) is neutral.
    public init(_ name: String?) {
        self = name.flatMap { VoiceMood(rawValue: $0.lowercased()) } ?? .neutral
    }

    /// Pace scales the AVSpeech rate (Kokoro reads it back as its speed);
    /// pitch multiplies the voice's own, on Apple voices only. Small on purpose:
    /// past about 15% a voice stops sounding moody and starts sounding broken.
    /// A first pass, to tune by ear.
    public var prosody: (speed: Float, pitch: Float) {
        switch self {
        case .neutral: (1.00, 1.00)
        case .happy: (1.05, 1.04)
        case .excited: (1.12, 1.08)
        case .surprised: (1.08, 1.10)
        case .love: (0.95, 1.03)
        case .thinking: (0.93, 0.98)
        case .sad: (0.88, 0.94)
        case .sleepy: (0.85, 0.92)
        case .angry: (1.06, 0.95)
        }
    }
}

public extension SpeechUtterance {
    /// An utterance in this mood. AVSpeech's rate scale is 0...1 around 0.5, so
    /// the pace scales the default rate; Kokoro reads it back as `speedMultiplier`.
    init(text: String, mood: VoiceMood) {
        let prosody = mood.prosody
        self.init(text: text, rate: Self.defaultRate * prosody.speed, pitch: Self.defaultPitch * prosody.pitch)
    }

    /// The rate as a multiple of the default: the speed for a voice that takes a
    /// speed rather than an AVSpeech rate.
    var speedMultiplier: Float {
        rate / Self.defaultRate
    }
}
