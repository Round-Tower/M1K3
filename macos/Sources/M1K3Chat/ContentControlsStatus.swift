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
                title: "No age range declared", systemImage: "person.crop.circle",
                actionTitle: "Set up", canClear: false
            )
        case .adult:
            ContentControlsStatus(
                title: "Adult: no adjustments", systemImage: "person.crop.circle.badge.checkmark",
                actionTitle: "Update", canClear: true
            )
        case .under13, .teen13to15, .teen16to17:
            ContentControlsStatus(
                title: "Age-appropriate adjustments active", systemImage: "person.crop.circle.badge.checkmark",
                actionTitle: "Update", canClear: true
            )
        }
    }
}
