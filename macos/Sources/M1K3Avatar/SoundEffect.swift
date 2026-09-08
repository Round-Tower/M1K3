//
//  SoundEffect.swift
//  M1K3Avatar
//
//  M1K3's UI earcons — short, playful sounds for a few key moments (an error,
//  a memory saved, voice mode coming alive). Deliberately a SMALL set: sound is
//  delight in small doses and noise in large ones. Since 2026-09-08 every
//  effect but the dial-up is SYNTHESISED by `EarconSynth` (one instrument, one
//  timbre); the dial-up stays a bundled WAV. "Every effect is playable" —
//  bundled resolves, synth renders — is pinned by SoundEffectTests.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-12, Confidence 0.85 (catalogue +
//  bundling test-pinned; the WAV choices are by-ear, swap a line to retune).
//  Prior: Unknown (sounds salvaged from the Python-era ./sounds/ library).
//  Review: Kev + claude-fable-5.1, 2026-09-08 — the vocabulary grows to eleven and every earcon but the dial-up is
//  SYNTHESISED (`EarconSynth`, `Source.synth`); the three salvaged WAVs retire. Confidence now 0.8.
//

import Foundation

/// A named UI sound. The raw value is stable identity; `source` says whether
/// `EarconSynth` renders it or a bundled WAV voices it (decoupled so a sound
/// can be re-cast without touching call sites).
///
/// Mostly short one-shot earcons — with one deliberate exception: `dialup` is a
/// SUSTAINED "connecting…" sound played on a loop while a model downloads/loads
/// (start/stop via `SoundEffectPlayer.startLoop`/`stopLoop`), not a fire-and-
/// forget blip. It still rides the same on/off toggle and player.
public enum SoundEffect: String, CaseIterable, Sendable {
    /// Something failed — a turn errored, a tool died.
    case error
    /// A durable memory was written (the MCP `remember` confirmation).
    case save
    /// Voice mode came alive — M1K3 materialising.
    case voiceEnter
    /// …and leaving — the sweep mirrored, down.
    case voiceExit
    /// The mic opened for a listen.
    case listenStart
    /// You finished speaking and M1K3 took it.
    case endpointHeard
    /// A heartbeat while it thinks (rendered; not yet wired — a loop is easy to overdo).
    case thinkingTick
    /// M1K3 reached for a tool (rendered; wiring rides the activity seam later).
    case toolCall
    /// The answer finished streaming.
    case answerLanded
    /// The user stopped an answer mid-stream.
    case stop
    /// The signature — M, 1, K, 3 as four notes. An asset for the brand, not a UI beat.
    case soundMark
    /// Sustained modem-handshake "connecting…" — looped while a model
    /// downloads/loads. Nostalgic dial-up; stops the moment the brain's ready.
    case dialup

    /// Where the sound comes from: synthesised by `EarconSynth` at init, or a
    /// bundled WAV under `SoundEffects/` (only the dial-up — real modem texture
    /// no short recipe replaces).
    public enum Source: Equatable, Sendable {
        case synth
        case bundled(String)
    }

    public var source: Source {
        switch self {
        case .dialup: .bundled("dialup")
        case .error, .save, .voiceEnter, .voiceExit, .listenStart, .endpointHeard, .thinkingTick,
             .toolCall, .answerLanded, .stop, .soundMark: .synth
        }
    }
}

/// Locates the bundled WAVs. Mirrors `CompanionAssets` — resources are copied
/// verbatim into `Bundle.module` under `SoundEffects/`.
public enum SoundEffectAssets {
    public static func url(for effect: SoundEffect) -> URL? {
        guard case let .bundled(name) = effect.source else { return nil }
        return Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "SoundEffects")
    }

    /// True when every catalogue entry is playable: a bundled entry has its
    /// WAV, a synth entry renders — the call sites can never name a silent
    /// sound (asserted in tests, like the companion clips).
    public static var allInstalled: Bool {
        SoundEffect.allCases.allSatisfy { effect in
            switch effect.source {
            case .bundled: url(for: effect) != nil
            case .synth: EarconSynth.render(effect)?.isEmpty == false
            }
        }
    }
}
