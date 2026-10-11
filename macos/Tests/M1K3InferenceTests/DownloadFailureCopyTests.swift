//
//  DownloadFailureCopyTests.swift
//  M1K3InferenceTests
//
//  The failure-copy mapper behind every download row, and the retry hook that lets a
//  module which owns an error type (Hub, the weight integrity gate) classify it
//  without M1K3Inference importing it (#557).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8. Prior: none (new file).

import Foundation
@testable import M1K3Inference
import Testing

private struct FakeClassified: DownloadFailureClassifying {
    let downloadFailureKind: DownloadFailureKind?
}

struct DownloadFailureCopyTests {
    @Test("offline and timeout read as a connection problem, with a next step")
    func offline() {
        let errors: [Error] = [
            URLError(.timedOut), URLError(.notConnectedToInternet),
            URLError(.networkConnectionLost), FakeClassified(downloadFailureKind: .offline),
        ]
        for error in errors {
            let copy = DownloadFailureCopy.message(for: error)
            #expect(copy.localizedCaseInsensitiveContains("connection"), "\(error)")
            #expect(copy.localizedCaseInsensitiveContains("try again"), "\(error)")
        }
    }

    @Test("a full disk says so and says what to do")
    func diskFull() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: posix])
        let errors: [Error] = [cocoa, posix, wrapped, FakeClassified(downloadFailureKind: .diskFull)]
        for error in errors {
            let copy = DownloadFailureCopy.message(for: error)
            #expect(copy.localizedCaseInsensitiveContains("space"), "\(error)")
            #expect(copy.localizedCaseInsensitiveContains("remove"), "\(error)")
        }
    }

    @Test("an integrity refusal uses its own short message, not a raw dump")
    func integrity() {
        let error = FakeClassified(downloadFailureKind: .integrity(message: "Those files didn't check out."))
        #expect(DownloadFailureCopy.message(for: error) == "Those files didn't check out.")
        #expect(DownloadFailureCopy.kind(of: error) == .integrity(message: "Those files didn't check out."))
    }

    @Test("anything else is honest about being unknown and still actionable")
    func unknown() {
        struct Odd: LocalizedError { var errorDescription: String? {
            "Odd thing"
        } }
        let copy = DownloadFailureCopy.message(for: Odd())
        #expect(copy.contains("Odd thing"))
        #expect(copy.localizedCaseInsensitiveContains("try again"))
        #expect(DownloadFailureCopy.kind(of: Odd()) == .unknown)
    }

    @Test("knownMessage speaks only for classes it understands, so a non-download failure keeps its own words")
    func knownMessage() {
        struct Odd: Error {}
        #expect(DownloadFailureCopy.knownMessage(for: URLError(.timedOut)) != nil)
        #expect(DownloadFailureCopy.knownMessage(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) != nil)
        #expect(DownloadFailureCopy.knownMessage(for: Odd()) == nil)
        #expect(DownloadFailureCopy.knownMessage(for: CancellationError()) == nil)
    }

    @Test("cancellation is not a failure")
    func cancellation() {
        #expect(DownloadFailureCopy.kind(of: CancellationError()) == .cancelled)
        #expect(DownloadFailureCopy.kind(of: URLError(.cancelled)) == .cancelled)
    }

    @Test("the retry predicate honours a module's own classification: offline retries, the rest do not")
    func retryHook() {
        #expect(RetryPolicy.isTransientNetworkError(FakeClassified(downloadFailureKind: .offline)))
        #expect(!RetryPolicy.isTransientNetworkError(FakeClassified(downloadFailureKind: .diskFull)))
        #expect(!RetryPolicy.isTransientNetworkError(FakeClassified(downloadFailureKind: .integrity(message: "x"))))
        #expect(!RetryPolicy.isTransientNetworkError(FakeClassified(downloadFailureKind: nil)))
    }
}
