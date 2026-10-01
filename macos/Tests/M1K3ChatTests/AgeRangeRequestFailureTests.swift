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
}
