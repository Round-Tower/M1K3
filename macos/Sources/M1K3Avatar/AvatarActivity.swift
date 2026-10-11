//
//  AvatarActivity.swift
//  M1K3Avatar
//
//  What M1K3 is currently doing — drives animation tier selection and procedural motion.
//
//  Signed: Kev + claude-sonnet-4-6, 2026-06-08, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-11 — `voiceOverAnnouncement(from:)`: the chat's panel (the
//  only VoiceOver-readable avatar) is retired and the backdrop stays decorative, so state reaches
//  VoiceOver as announcements — a turn starting, the voice states, an error; never generating or
//  idle (every turn would chatter). Confidence 0.8 (the policy is tested; the posting is by ear).

public enum AvatarActivity: String, CaseIterable, Sendable {
    case idle
    case listening
    case thinking
    case generating
    case speaking
    case error

    /// True when M1K3 is actively engaged — drives faster procedural animation.
    public var isActive: Bool {
        switch self {
        case .idle, .error: false
        default: true
        }
    }

    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .generating: "Generating…"
        case .speaking: "Speaking…"
        case .error: "Error"
        }
    }

    /// The one-word status a badge shows — with the SAME recording-wins
    /// precedence `glyphTreatment(isRecording:)` pins for the dot colour, so
    /// the text can never say "Idle" beside a red recording dot. Idle reads
    /// as "Ready" (the badge idiom), active states keep their displayName.
    public func statusLabel(isRecording: Bool) -> String {
        if isRecording { return "Recording" }
        return self == .idle ? "Ready" : displayName
    }

    /// A VoiceOver-friendly phrase naming M1K3 and what it's doing — same cases as
    /// `displayName`, but without the trailing ellipsis (VoiceOver reads "…" as
    /// literal dots, not "in progress"). Composed once here so every surface that
    /// speaks the avatar's state (the hero panel, voice mode) says the same thing.
    public var accessibilityLabel: String {
        let state: String
        switch self {
        case .idle: state = "Idle"
        case .listening: state = "Listening"
        case .thinking: state = "Thinking"
        case .generating: state = "Generating"
        case .speaking: state = "Speaking"
        case .error: state = "Error"
        }
        return "M1K3 — \(state)"
    }

    /// What VoiceOver should announce when M1K3 moves from `previous` to this state, or nil to
    /// stay quiet: a turn starting (thinking), the voice states and errors. Generating and idle
    /// are the middle and end of every turn, and announcing them would talk over the answer.
    public func voiceOverAnnouncement(from previous: AvatarActivity) -> String? {
        guard self != previous else { return nil }
        switch self {
        case .thinking, .listening, .speaking, .error: return accessibilityLabel
        case .idle, .generating: return nil
        }
    }
}
