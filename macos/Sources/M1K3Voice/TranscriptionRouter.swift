//
//  TranscriptionRouter.swift
//  M1K3Voice
//
//  Picks among configured TranscriptionProviders by availability and order —
//  a simple, tested availability-ordered selector. List the primary (WhisperKit,
//  best accuracy) first and Apple Speech (always-available fallback) second; the
//  first available one serves.
//
//  Holds no mutable state (an immutable ordered list of Sendable providers), so
//  it's a value type. It is purely a *selector*: callers capture `activeProvider`
//  once at session start and call start/stop on that captured reference — the
//  router deliberately exposes no session methods, because re-resolving the
//  provider at stop time could target a different engine than start did (e.g. if
//  WhisperKit's model finished loading mid-session).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85,
//  Prior: internal call-pipeline project, TranscriptionRouter (Kev) — simplified to a plain
//  availability-ordered selector (no PerformanceMonitor, no buffer fallback chain).

import Foundation

public struct TranscriptionRouter: Sendable {
    public let providers: [any TranscriptionProvider]

    public init(providers: [any TranscriptionProvider]) {
        self.providers = providers
    }

    /// The provider that would currently serve, if any.
    public var activeProvider: (any TranscriptionProvider)? {
        providers.first { $0.isAvailable }
    }

    /// The provider to serve this listen, optionally preferring one whose mic path
    /// we can put echo cancellation and other-audio ducking on.
    ///
    /// Voice-first mode is a hands-free conversation held over speakers, so when
    /// other audio is in play the room matters more than the last few points of
    /// word accuracy: an engine that hears the music transcribes the music (and
    /// M1K3's own voice back at itself). Chat dictation is the other way round —
    /// one short push-to-talk burst, usually quiet — so it keeps the sharper
    /// engine by leaving this flag off.
    ///
    /// A PREFERENCE, never a requirement: if nothing echo-cancelling is available
    /// it falls back to normal ordering, because listening on the sharper engine
    /// beats refusing to listen.
    public func activeProvider(preferringEchoCancellation: Bool) -> (any TranscriptionProvider)? {
        guard preferringEchoCancellation else { return activeProvider }
        return providers.first { $0.isAvailable && $0.attemptsEchoCancellation } ?? activeProvider
    }

    public var activeProviderName: String? {
        activeProvider?.name
    }
}
