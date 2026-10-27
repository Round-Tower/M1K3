//
//  AgeBandPolicyTests.swift
//  M1K3ChatTests
//
//  Pins the age-adaptive policy core (PLAN.md item 19). Non-negotiables:
//    - ZERO PII: the band is a coarse local enum, mapped from the Declared
//      Age Range API's bounds (gates 13/16/18) — never an age, never stored
//      beyond the enum's rawValue.
//    - Declining must NOT degrade: .undeclared is pinned byte-identical to
//      .adult (full capability, no clause). Age-assurance, not verification.
//    - Policy→prompt for tone, enforcement→code for safety: minor bands get
//      a prompt clause AND a hard web-tools gate (prompt alone is not a
//      safety boundary — the CanaryGuard doctrine).
//
//  Signed: Kev + claude-fable-5, 2026-07-13, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-26 — #708: the field report ("Send this exchange", an email to
//  Round Tower) is withheld from the same two bands as the web tools, pinned per band. Confidence 0.85.
//

import Foundation
@testable import M1K3Chat
import Testing

struct AgeBandMappingTests {
    // The API returns bounds relative to our gates (13, 16, 18):
    // nil lowerBound = below the lowest gate; nil upperBound = at/above the highest.

    @Test func belowLowestGateIsUnder13() {
        #expect(AgeBand(lowerBound: nil, upperBound: 12) == .under13)
    }

    @Test func nilLowerBoundIsUnder13RegardlessOfBoundConvention() {
        // Review-caught fail-open: "nil lowerBound = below the lowest gate" is
        // the API's meaning, full stop. If Apple's upper bound turns out to be
        // inclusive — (nil, 13), not (nil, 12) — a numeric `< 13` guard would
        // silently hand the YOUNGEST band full adult capability. Any
        // (nil, .some) is under13; only (nil, nil) is truly no-signal.
        #expect(AgeBand(lowerBound: nil, upperBound: 13) == .under13)
        #expect(AgeBand(lowerBound: nil, upperBound: 5) == .under13)
    }

    @Test func thirteenToFifteen() {
        #expect(AgeBand(lowerBound: 13, upperBound: 15) == .teen13to15)
    }

    @Test func sixteenToSeventeen() {
        #expect(AgeBand(lowerBound: 16, upperBound: 17) == .teen16to17)
    }

    @Test func openUpperBoundIsAdult() {
        #expect(AgeBand(lowerBound: 18, upperBound: nil) == .adult)
    }

    @Test func bothBoundsNilIsUndeclared() {
        // An ambiguous response carries no information — treat as undeclared
        // (full capability), never guess a minor band from nothing.
        #expect(AgeBand(lowerBound: nil, upperBound: nil) == .undeclared)
    }

    @Test func persistedRoundTripsAndUnknownDegradesToUndeclared() {
        for band in AgeBand.allCases {
            #expect(AgeBand(persisted: band.rawValue) == band)
        }
        #expect(AgeBand(persisted: nil) == .undeclared)
        #expect(AgeBand(persisted: "corrupted-junk") == .undeclared)
    }
}

struct AgeAppropriatenessPolicyTests {
    @Test func adultIsFullCapabilityWithNoClause() {
        let policy = AgeAppropriateness.policy(for: .adult)
        #expect(policy.webToolsAllowed)
        #expect(policy.promptClause == nil)
    }

    @Test func undeclaredIsIdenticalToAdult() {
        // THE brand pin: declining to share an age range must not degrade
        // the experience in any way.
        #expect(AgeAppropriateness.policy(for: .undeclared) == AgeAppropriateness.policy(for: .adult))
    }

    @Test func under16BandsGateWebToolsHard() {
        for band in [AgeBand.under13, .teen13to15] {
            let policy = AgeAppropriateness.policy(for: band)
            #expect(!policy.webToolsAllowed, "\(band) must gate web tools in code, not just prompt")
            #expect(policy.promptClause?.isEmpty == false)
        }
    }

    @Test func olderTeensKeepWebWithAClause() {
        let policy = AgeAppropriateness.policy(for: .teen16to17)
        #expect(policy.webToolsAllowed)
        #expect(policy.promptClause?.isEmpty == false)
    }

    @Test func minorClausesNeverMentionAgeNumbersOrTheAPI() {
        // The clause rides the DYNAMIC persona prompt — it must never leak
        // band mechanics ("13-15", "declared age range") into generations.
        for band in [AgeBand.under13, .teen13to15, .teen16to17] {
            let clause = AgeAppropriateness.policy(for: band).promptClause ?? ""
            let containsDigit = clause.contains { $0.isNumber }
            #expect(!containsDigit, "\(band) clause leaks a number")
            #expect(!clause.localizedCaseInsensitiveContains("age range"))
        }
    }

    @Test func fieldReportIsWithheldFromUnder16Bands() {
        // #708: a thumbs-down can offer to email the exchange to Round Tower. Under 13 is COPPA's
        // line and 16 is Ireland's digital age of consent, so those two bands never see the offer.
        // Enforced in code (the Mac shell hides the button), like the web tools.
        let expected: [AgeBand: Bool] = [
            .under13: false, .teen13to15: false, .teen16to17: true, .adult: true, .undeclared: true,
        ]
        for band in AgeBand.allCases {
            #expect(AgeAppropriateness.fieldReportAllowed(for: band) == expected[band], "\(band)")
        }
    }
}
