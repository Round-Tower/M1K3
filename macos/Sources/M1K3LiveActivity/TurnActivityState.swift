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
    /// An answer made on this phone's GPU was stopped when the app left (iOS refuses background
    /// GPU work); opening M1K3 is the way back.
    case paused
}

/// The Live Activity's dynamic content: the phase, and no free text.
public struct TurnActivityState: Codable, Hashable, Sendable {
    public var phase: TurnActivityPhase

    public init(phase: TurnActivityPhase) {
        self.phase = phase
    }
}
