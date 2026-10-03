#if canImport(DeclaredAgeRange)
    import DeclaredAgeRange
#endif
import Foundation
@testable import M1K3Chat
import Testing

/// The Content Controls "Set up" button used to swallow every failure: on the
/// Mac (no entitlement, build 375) the tap did nothing at all (Kev, 2026-10-01).
/// Every failure now says what happened and what to try — and none of them
/// changes the persisted band (a failed ask is not a decline).
struct AgeRangeRequestFailureTests {
    @Test("every failure has a message, and they're distinct where the fix differs")
    func everyFailureSpeaks() {
        for failure in AgeRangeRequestFailure.allCases {
            #expect(!failure.message.isEmpty, "\(failure) is silent")
        }
        #expect(AgeRangeRequestFailure.invalidAccount.message != AgeRangeRequestFailure.network.message)
        #expect(AgeRangeRequestFailure.notAvailable.message != AgeRangeRequestFailure.network.message)
    }

    @Test("an account problem names the Apple Account; a network one names the connection")
    func messagesNameTheFix() {
        #expect(AgeRangeRequestFailure.invalidAccount.message.contains("Apple Account"))
        #expect(AgeRangeRequestFailure.network.message.contains("connection"))
    }

    @Test("no failure claims an age or a band — a failed ask is not a decline")
    func noFailureClaimsABand() {
        for failure in AgeRangeRequestFailure.allCases {
            #expect(!failure.message.localizedStandardContains("under 16"))
            #expect(!failure.message.localizedStandardContains("adult"))
        }
    }

    @Test("Apple's error maps by case NAME — the shells never link a case symbol")
    func mapsByCaseName() {
        #expect(AgeRangeRequestFailure(appleCaseName: "notAvailable") == .notAvailable)
        #expect(AgeRangeRequestFailure(appleCaseName: "invalidAccount") == .invalidAccount)
        #expect(AgeRangeRequestFailure(appleCaseName: "network") == .network)
        #expect(AgeRangeRequestFailure(appleCaseName: "declinedOnboarding") == .declinedOnboarding)
        #expect(AgeRangeRequestFailure(appleCaseName: "invalidRequest") == .other)
        #expect(AgeRangeRequestFailure(appleCaseName: "somethingApplesAddsNext") == .other)
    }

    /// 2026-10-03: `case .invalidAccount` in the shells' switch strong-linked
    /// `AgeRangeService.Error.invalidAccount`'s case symbol, which the Xcode 27
    /// SDK declares with no availability — and iOS 26.5 / the iOS 27 beta
    /// runtime don't export. dyld killed the app at launch ("Symbol not found:
    /// …invalidAccountyA2EmFWC") before a line of it ran. A switch over a system
    /// enum's cases is a launch-time dependency on every case named.
    @Test("no shell names AgeRangeService.Error's cases")
    func shellsNameNoAppleCases() throws {
        let macos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Any spelling links the case symbol: `case .x:`, `case .x, .y`, `== .x`,
        // `AgeRangeService.Error.x`, `catch …x`. The shells use none of these names
        // for anything else, so the pattern needs no exclusions.
        let named = try Regex(#"\.(notAvailable|invalidRequest|invalidAccount|declinedOnboarding|network)\b"#)
        for shell in ["M1K3iOSApp/SettingsScreen.swift", "M1K3App/Settings/PrivacySettingsPane.swift"] {
            let source = try String(contentsOf: macos.appendingPathComponent(shell), encoding: .utf8)
            #expect(source.contains("appleCaseName:"), "\(shell) maps by case name")
            for line in source.split(separator: "\n") where line.contains(named) {
                Issue.record("\(shell) names an AgeRangeService.Error case: \(line)")
            }
        }
    }

    #if canImport(DeclaredAgeRange)
        /// The canary: Apple's enum still prints its bare case name. ONLY the two
        /// cases older runtimes export (`nm` on the iOS 27 beta runtime lists just
        /// `notAvailable` + `invalidRequest`) — naming `.network` here dyld-crashed
        /// this very test binary on the macOS 26.5 CI runner (2026-10-03).
        @Test("Apple's error describes itself by bare case name")
        func appleCaseNamesAreBare() {
            let notAvailable = String(describing: AgeRangeService.Error.notAvailable)
            let invalidRequest = String(describing: AgeRangeService.Error.invalidRequest)
            #expect(AgeRangeRequestFailure(appleCaseName: notAvailable) == .notAvailable)
            #expect(invalidRequest == "invalidRequest")
        }
    #endif
}
