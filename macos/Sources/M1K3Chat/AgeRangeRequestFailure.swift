//
//  AgeRangeRequestFailure.swift
//  M1K3Chat
//
//  Why a Declared Age Range request didn't come back with an answer, and what
//  the Content Controls row says about it. The app maps AgeRangeService.Error
//  here at the boundary (this module never imports DeclaredAgeRange). A failed
//  ask leaves the persisted band alone: it is not a decline.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-01, Confidence 0.85 (pure copy, pinned;
//  the sheet itself is verify-by-launch). The "Set up" button swallowed every
//  error, and the store build carried no declared-age-range entitlement, so on
//  the Mac the tap did nothing at all. Prior: none (new file).
//

import Foundation

public enum AgeRangeRequestFailure: CaseIterable, Sendable, Equatable {
    /// Apple's `notAvailable`: the service can't answer here (no entitlement,
    /// region, OS). Apple's docs also route some declines here.
    case notAvailable
    case invalidAccount
    case network
    /// The user hasn't finished setting up age range sharing for the account.
    case declinedOnboarding
    /// `invalidRequest`, no window to present on, or anything unknown.
    case other

    public var message: String {
        switch self {
        case .notAvailable:
            "Apple's age range sharing isn't available here right now, so nothing has changed."
        case .invalidAccount:
            "Sign in with your Apple Account in Settings, then try again."
        case .network:
            "Couldn't reach Apple. Check your connection and try again."
        case .declinedOnboarding:
            "Age range sharing isn't set up for this account yet, so nothing has changed."
        case .other:
            "Couldn't ask for an age range just now. Try again in a moment."
        }
    }
}
