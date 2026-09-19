//
//  AgeBandProviding.swift
//  M1K3Chat
//
//  The runtime seam for the declared age band. App targets provide a live
//  implementation (DeclaredAgeRange API → UserDefaults); tests inject a
//  fixed band. The protocol lives here (not M1K3Inference) because both
//  consumers — the web-tool gate and the prompt clause — live in M1K3Chat.

import Foundation

/// Provides the current user's declared age band. The app reads it from
/// persisted UserDefaults (written after a DeclaredAgeRange system sheet);
/// tests inject a fixed value.
public protocol AgeBandProviding: Sendable {
    func currentBand() -> AgeBand
}

/// Fixed band for tests and previews.
public struct FixedAgeBandProvider: AgeBandProviding {
    private let band: AgeBand
    public init(_ band: AgeBand) {
        self.band = band
    }

    public func currentBand() -> AgeBand {
        band
    }
}

/// Reads the persisted band from UserDefaults; writes after the system sheet.
/// Pure Foundation — no DeclaredAgeRange import (that lives in the app target).
public final class PersistedAgeBandProvider: AgeBandProviding, @unchecked Sendable {
    public static let defaultsKey = "ageBandRawValue"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func currentBand() -> AgeBand {
        AgeBand(persisted: defaults.string(forKey: Self.defaultsKey))
    }

    public func persist(_ band: AgeBand) {
        defaults.set(band.rawValue, forKey: Self.defaultsKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
