//
//  TurnActivityState.swift
//  M1K3LiveActivity
//
//  What the iPhone's Live Activity (Lock Screen + Dynamic Island) shows for a long answer or
//  a file read: a PHASE, nothing else. Never the question, a file name, a transcript or any
//  answer text: the Lock Screen is readable by anyone holding a locked phone, and the push-token
//  path (which would send state through a server) is not used at all: updates are local.
//  TurnActivityStateTests pins the shape (one key, a closed enum).
//
//  Foundation-only on purpose. The widget extension has a ~30 MB memory ceiling and must not
//  link MLX or the chat stack; the macOS 27.3 Live Activities (same ActivityKit code) will adopt
//  this module as it stands.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.8 (shape pinned by test; the look
//  on a real phone is verify-on-device), Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-26 — two phases for a voice conversation behind the lock (`listening`,
//  `speaking`, salvaged from the spike/bg-voice spike): still phase words only, nothing that was said.
//  Confidence 0.8.

import Foundation

/// Where a turn is. Raw values are the wire words, so a rename is a deliberate act.
public enum TurnActivityPhase: String, Codable, Sendable, CaseIterable {
    /// The brain is working and nothing has streamed yet.
    case thinking
    /// The brain is reading a file or paste someone sent (the read route).
    case reading
    /// Words are arriving.
    case answering
    /// The answer finished while the person was elsewhere.
    case ready
    /// The answer was stopped when the app left (iOS refuses background GPU work, and the stop reads the
    /// loaded brain, not the turn's route, so the words stay route-neutral); opening M1K3 is the way back.
    case paused
    /// A voice conversation behind the lock, waiting for the person to talk.
    case listening
    /// A voice conversation behind the lock: M1K3 is saying the answer aloud.
    case speaking
}

/// The Live Activity's dynamic content: the phase, and no free text.
public struct TurnActivityState: Codable, Hashable, Sendable {
    public var phase: TurnActivityPhase

    public init(phase: TurnActivityPhase) {
        self.phase = phase
    }
}
