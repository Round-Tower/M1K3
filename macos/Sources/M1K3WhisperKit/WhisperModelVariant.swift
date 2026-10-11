//
//  WhisperModelVariant.swift
//  M1K3WhisperKit
//
//  The user-selectable WhisperKit accuracy tier. The default is `small.en` — a
//  clear accuracy step up from `base.en` for a still-reasonable (~480 MB) download
//  on Apple Silicon — so transcripts are sharper out of the box, which is the
//  cheapest lever on "the model can't reason over what it's given". Tiny/base
//  remain available for constrained machines via the Settings picker.
//
//  Pure value type, so the picker + storage parsing are unit-tested; the actual
//  model download/load stays verify-by-launch in WhisperKitProvider.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-11 — `approxBytes`, the sizeHint's figure as a number for
//  Settings > Brains & downloads (pinned to the hint by a test). Confidence 0.85.

import Foundation

public enum WhisperModelVariant: String, CaseIterable, Identifiable, Sendable {
    case tiny = "tiny.en"
    case base = "base.en"
    case small = "small.en"

    public var id: String {
        rawValue
    }

    /// The variant string WhisperKit expects (`init(model:)` / `downloadBase`).
    public var modelID: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .tiny: "Tiny"
        case .base: "Base"
        case .small: "Small"
        }
    }

    /// Size + character hint for the picker row.
    public var sizeHint: String {
        switch self {
        case .tiny: "~75 MB · fastest, least accurate"
        case .base: "~145 MB · balanced"
        case .small: "~480 MB · most accurate"
        }
    }

    /// The same figure in bytes, for the downloads list. WhisperKit's repo is not pinned,
    /// so this is an estimate, and the list says so.
    public var approxBytes: Int64 {
        switch self {
        case .tiny: 75_000_000
        case .base: 145_000_000
        case .small: 480_000_000
        }
    }

    /// The shipped default — accuracy-first within a reasonable download.
    public static let defaultVariant: WhisperModelVariant = .small

    /// Resolve a stored preference, falling back to the default for a missing or
    /// unrecognised value (e.g. an older build's key, or a hand-edited default).
    public static func from(stored: String?) -> WhisperModelVariant {
        stored.flatMap(WhisperModelVariant.init(rawValue:)) ?? .defaultVariant
    }

    /// Resolve the variant to use at launch. An EXPLICIT stored pick always wins.
    /// With no pick, prefer a variant whose model is ALREADY installed (best
    /// accuracy first) over the shipped default — so a returning user who had
    /// WhisperKit on, say, `base.en` keeps it instead of being silently switched to
    /// `small.en` and forced into a fresh ~480 MB download. `isInstalled` is injected
    /// so the decision is unit-testable without touching the filesystem.
    public static func resolve(
        stored: String?,
        isInstalled: (WhisperModelVariant) -> Bool
    ) -> WhisperModelVariant {
        if let stored, let explicit = WhisperModelVariant(rawValue: stored) { return explicit }
        let bestFirst: [WhisperModelVariant] = [.small, .base, .tiny]
        return bestFirst.first(where: isInstalled) ?? .defaultVariant
    }
}
