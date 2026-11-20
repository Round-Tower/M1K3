//
//  ContentControlsStatus.swift
//  M1K3Chat
//
//  What the Content Controls row in Settings (Mac + iOS) says about the stored
//  band. Both shells used to decide inline from "is a minor band", so an adult
//  who shared their age range read "No age range declared" beside a "Clear" and
//  an "Update" that said the opposite (2026-10-09). One pure answer, both shells.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-09, Confidence 0.9 (every band pinned in
//  ContentControlsStatusTests). Prior: none (new file).
//  Review: claude-opus-5-5, 2026-11-19 — localisable (l10n Phase 0): every title and action
//  resolves from M1K3Chat's catalog (`bundle: .module`). Display-only (rg: the two Settings
//  rows and the tests read it; nothing model-facing). English unchanged. Confidence 0.9.
//

import Foundation

public struct ContentControlsStatus: Equatable, Sendable {
    public let title: String
    public let systemImage: String
    /// "Set up" before anything is shared, "Update" after.
    public let actionTitle: String
    /// Whether there is a stored band to forget.
    public let canClear: Bool
}

public extension AgeBand {
    var contentControlsStatus: ContentControlsStatus {
        switch self {
        case .undeclared:
            ContentControlsStatus(
                title: String(localized: "No age range declared", bundle: .module, comment: "Settings ▸ Content Controls: no age range has been shared"),
                systemImage: "person.crop.circle",
                actionTitle: String(localized: "Set up", bundle: .module, comment: "Settings ▸ Content Controls button: share an age range for the first time"),
                canClear: false
            )
        case .adult:
            ContentControlsStatus(
                title: String(localized: "Adult: no adjustments", bundle: .module, comment: "Settings ▸ Content Controls: an adult age range is stored, so nothing is adjusted"),
                systemImage: "person.crop.circle.badge.checkmark",
                actionTitle: String(localized: "Update", bundle: .module, comment: "Settings ▸ Content Controls button: share the age range again"),
                canClear: true
            )
        case .under13, .teen13to15, .teen16to17:
            ContentControlsStatus(
                title: String(localized: "Age-appropriate adjustments active", bundle: .module, comment: "Settings ▸ Content Controls: a minor's age range is stored, so content is adjusted"),
                systemImage: "person.crop.circle.badge.checkmark",
                actionTitle: String(localized: "Update", bundle: .module, comment: "Settings ▸ Content Controls button: share the age range again"),
                canClear: true
            )
        }
    }
}
