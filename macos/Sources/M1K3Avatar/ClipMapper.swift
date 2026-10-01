//
//  ClipMapper.swift
//  M1K3Avatar
//
//  AvatarState → companion animation clip. The pixel face reads the same
//  AvatarState through FaceExpression; this is its 3D sibling. Pure resolver:
//  state → a dialect-independent `CompanionGait` → the dialect's actual clip
//  name. The two-step keeps the "what mood" decision in one place and the "which
//  file" decision per-dialect, so a companion can never be asked for a clip it
//  doesn't ship (CompanionTests pins that invariant).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-11, Confidence 0.75 (mapping by-design,
//  crossfade timings are by-eye starting points), Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-10-01 — `gait(for:)` is now the LOOP gait only: excited no longer
//  wins `.react` (it made a streaming reply loop Jump/Run and hid the move clip — the choreography bug);
//  sleepy-at-idle → `.sleepy`. Three new gaits + crossfades. Confidence now 0.8.

/// The abstract motion a companion shows — independent of which creature it is.
/// Each `CompanionDialect` resolves a gait to one of its bundled clips.
public enum CompanionGait: CaseIterable, Sendable {
    case rest // calm idle
    case alert // attentive — listening / thinking
    case move // engaged — generating / speaking
    case react // a beat of delight — a ONE-SHOT, never a loop (see CompanionChoreographer)
    case distress // error / upset
    case sleepy // settled, drowsy (sleepy emotion; the long-idle rest)
    case affection // a warm beat (love) — a one-shot
    case fidget // an idle flourish — a one-shot between rest loops
}

public enum ClipMapper {
    /// The LOOPING gait for a state. Distress emotions (and the error activity)
    /// win; a sleepy companion at idle settles; otherwise the activity drives.
    /// `.excited` deliberately does NOT pick `.react` here: generating derives
    /// excited, and a looping Jump/Run while a reply streamed was the "I only
    /// see 2/3 of the clips" bug. The react beat is a one-shot that
    /// `CompanionChoreographer` fires on the transition instead.
    public static func gait(for state: AvatarState) -> CompanionGait {
        if state.activity == .error || state.emotion == .angry || state.emotion == .sad {
            return .distress
        }
        switch state.activity {
        case .idle: return state.emotion == .sleepy ? .sleepy : .rest
        case .listening, .thinking: return .alert
        case .generating, .speaking: return .move
        case .error: return .distress // unreachable (caught above), kept total
        }
    }

    /// State → the clip filename to play for a given companion dialect.
    public static func clip(for state: AvatarState, dialect: CompanionDialect) -> String {
        dialect.clipName(for: gait(for: state))
    }

    /// Crossfade into a gait — reactions snap, settling is gentle. Seconds.
    public static func crossfadeDuration(to gait: CompanionGait) -> Double {
        switch gait {
        case .react, .distress, .affection: 0.15
        case .move, .alert, .fidget: 0.25
        case .rest: 0.35
        case .sleepy: 0.5
        }
    }
}
