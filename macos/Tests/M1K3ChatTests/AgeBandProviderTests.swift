//
//  AgeBandProviderTests.swift
//  M1K3ChatTests
//
//  Pins the persistence + runtime behaviour of the age-band provider.
//  The DeclaredAgeRange API (system sheet) is app-target glue; these tests
//  cover the pure read/write/clear seam and the FixedAgeBandProvider stub.

import Foundation
@testable import M1K3Chat
import Testing

struct PersistedAgeBandProviderTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "test.ageband.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("no persisted value reads as undeclared — declining must not degrade")
    func defaultIsUndeclared() {
        let provider = PersistedAgeBandProvider(defaults: freshDefaults())
        #expect(provider.currentBand() == .undeclared)
    }

    @Test("persist and read back every band")
    func persistRoundTrip() {
        let defaults = freshDefaults()
        let provider = PersistedAgeBandProvider(defaults: defaults)
        for band in AgeBand.allCases {
            provider.persist(band)
            #expect(provider.currentBand() == band)
        }
    }

    @Test("clear resets to undeclared")
    func clearResetsToUndeclared() {
        let defaults = freshDefaults()
        let provider = PersistedAgeBandProvider(defaults: defaults)
        provider.persist(.under13)
        #expect(provider.currentBand() == .under13)
        provider.clear()
        #expect(provider.currentBand() == .undeclared)
    }

    @Test("corrupted persisted value degrades to undeclared")
    func corruptedDegrades() {
        let defaults = freshDefaults()
        defaults.set("not-a-real-band", forKey: PersistedAgeBandProvider.defaultsKey)
        let provider = PersistedAgeBandProvider(defaults: defaults)
        #expect(provider.currentBand() == .undeclared)
    }
}

struct FixedAgeBandProviderTests {
    @Test("fixed provider returns the band it was given")
    func fixedReturnsGiven() {
        for band in AgeBand.allCases {
            let provider = FixedAgeBandProvider(band)
            #expect(provider.currentBand() == band)
        }
    }
}

struct AgeBandWebToolGatingTests {
    @Test("under-16 bands gate web tools")
    func under16GatesWebTools() {
        for band in [AgeBand.under13, .teen13to15] {
            let policy = AgeAppropriateness.policy(for: band)
            #expect(!policy.webToolsAllowed, "\(band) must hard-gate web tools")
        }
    }

    @Test("16+ and undeclared allow web tools")
    func sixteenPlusAllowsWebTools() {
        for band in [AgeBand.teen16to17, .adult, .undeclared] {
            let policy = AgeAppropriateness.policy(for: band)
            #expect(policy.webToolsAllowed, "\(band) must allow web tools")
        }
    }

    @Test("prompt clause present for all minor bands, absent for adult and undeclared")
    func promptClausePresence() {
        for band in [AgeBand.under13, .teen13to15, .teen16to17] {
            #expect(AgeAppropriateness.policy(for: band).promptClause != nil)
        }
        #expect(AgeAppropriateness.policy(for: .adult).promptClause == nil)
        #expect(AgeAppropriateness.policy(for: .undeclared).promptClause == nil)
    }
}
