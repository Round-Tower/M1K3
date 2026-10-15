//
//  VoiceModeEarcons.swift
//  M1K3Avatar
//
//  Which earcons mark voice mode's start, for both shells. Kev, 2026-10-12 (iPhone): "the Voice sound effects on
//  start, can we use our new onboarding sound instead". Voice mode opens on the onboarding's wake chime (M1K3
//  coming alive) instead of the old sweep, and the first listen skips its mic-open tick: the chime already said
//  it, and the sweep plus the tick used to land ~0.5 s apart. Every later listen keeps the tick.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-12, Confidence 0.85 (pinned; the sound is verify-by-ear). Prior: none.
//

public enum VoiceModeEarcons {
    /// Voice mode opening: the onboarding's wake chime.
    public static let enter: SoundEffect = .wakeChime

    /// The mic-open tick, except on the first listen after `enter`.
    public static func listenStart(isFirstListen: Bool) -> SoundEffect? {
        isFirstListen ? nil : .listenStart
    }
}
