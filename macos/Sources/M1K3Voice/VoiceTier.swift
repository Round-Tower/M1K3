//
//  VoiceTier.swift
//  M1K3Voice
//
//  How M1K3 sounds when it speaks — the TTS analogue of BrainTier. Built-in is the
//  instant, zero-download Apple voice; M1K3 Voice is the richer neural voice
//  (Kokoro) that downloads once and then runs fully on-device. Drives the
//  onboarding voice-output card and the Settings picker.
//
//  Pure data: SF Symbol names are plain strings, no SwiftUI dependency, so this
//  stays testable in the package.
//
//  Signed: Kev + claude-sonnet-4-6, 2026-06-08, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-09-25 — M1K3 Voice quotes ~192 MB (decimal, as iOS shows it); 184 was the
//  MiB figure for the same bytes. Pinned to the Kokoro manifest by KokoroDownloadSizeTests. Confidence 0.9.
//  Review: claude-opus-5-5, 2026-11-19 — localisation Phase 0: `tagline` and `detail` resolve from M1K3Voice's
//  catalog (`bundle: .module`), each detail one literal (the `+` joins merged); `displayName` stays plain English
//  because MCP `get_status` reports it. English unchanged.
//  Review: claude-opus-5-5, 2026-11-19 — `localizedName`: the views' copy of the tier name ("Built-in" from the
//  catalog, "M1K3 Voice" catalogued shouldTranslate false); `displayName` stays the plain-English wire value.

import Foundation

public enum VoiceTier: String, CaseIterable, Identifiable, Sendable {
    case builtin
    case m1k3Voice

    public var id: String {
        rawValue
    }

    /// Plain English on purpose: MCP `get_status` reports it to agents (wire text, localisation plan §4).
    public var displayName: String {
        switch self {
        case .builtin: "Built-in"
        case .m1k3Voice: "M1K3 Voice"
        }
    }

    /// The name a VIEW shows (pickers, Settings). Never on a wire or in a prompt: those read
    /// `displayName`. "M1K3 Voice" is a brand and is catalogued `shouldTranslate: false`.
    public var localizedName: String {
        switch self {
        case .builtin:
            String(
                localized: "Built-in",
                bundle: .module,
                comment: "Voice tier name: the device's own system speech voice (no download)."
            )
        case .m1k3Voice:
            String(localized: "M1K3 Voice", bundle: .module, comment: "Voice tier name: never translated.")
        }
    }

    public var tagline: String {
        switch self {
        case .builtin: String(localized: "Ready now · no download", bundle: .module)
        case .m1k3Voice: String(localized: "Neural voice · ~192 MB", bundle: .module)
        }
    }

    public var detail: String {
        switch self {
        case .builtin:
            Self.builtinDetail
        case .m1k3Voice:
            Self.m1k3VoiceDetail
        }
    }

    /// Same platform-honesty rule as `m1k3VoiceDetail` below. Closed
    /// 2026-07-31: the Phase-B precondition ("voice isn't wired on mobile")
    /// died with the #82 mobile voice-first shell, so the copy stops naming
    /// macOS on devices that aren't one. macOS bytes frozen, pinned in
    /// VoiceTierTests.
    private static var builtinDetail: String {
        #if os(macOS)
            String(
                localized: "macOS's built-in speech. Works immediately, always on-device — clear, if a little robotic.",
                bundle: .module
            )
        #else
            String(
                localized: "Your device's built-in speech. Works immediately, always on-device — clear, if a little robotic.",
                bundle: .module
            )
        #endif
    }

    /// Platform-honest wording, hand-rolled rather than folded onto
    /// M1K3Inference's HostPlatform: M1K3Voice is deliberately dependency-free,
    /// and a Voice→Inference edge to dedupe one string is worse layering than
    /// the duplication. Consolidate if HostPlatform ever moves to a universal
    /// leaf (M1K3LogCore) or Phase-B voice wiring gives Voice the dep anyway.
    /// macOS bytes frozen, pinned in VoiceTierTests.
    private static var m1k3VoiceDetail: String {
        #if os(macOS)
            String(localized: """
            A warm, natural neural voice that runs entirely on your Mac. One download, then offline forever. \
            The voice M1K3 was meant to have.
            """, bundle: .module)
        #else
            String(localized: """
            A warm, natural neural voice that runs entirely on your device. One download, then offline forever. \
            The voice M1K3 was meant to have.
            """, bundle: .module)
        #endif
    }

    public var glyph: String {
        switch self {
        case .builtin: "speaker.wave.2"
        case .m1k3Voice: "speaker.wave.3.fill"
        }
    }

    /// One-time download size in DECIMAL MB (what iOS and the Finder show), or
    /// nil when nothing to download (Built-in). Pinned to Kokoro's manifest
    /// bytes by KokoroDownloadSizeTests — the old 184 was the MiB figure.
    public var approxDownloadMB: Int? {
        switch self {
        case .builtin: nil
        case .m1k3Voice: 192
        }
    }

    public var requiresDownload: Bool {
        approxDownloadMB != nil
    }
}
