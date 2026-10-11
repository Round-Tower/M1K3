//
//  DownloadFailureCopy.swift
//  M1K3Inference
//
//  What a failed download says to a person. Four honest outcomes — no connection,
//  no room, a refusal by the integrity gate, and "something else" — each with a
//  next step, instead of "The operation couldn't be completed".
//
//  The classification seam is a protocol, not an import: M1K3Inference stays
//  dependency-free, so the modules that OWN an error type (M1K3MLX for Hub's
//  `HubClientError` and the weight-integrity errors) conform their types here and
//  both this mapper and `RetryPolicy.isTransientNetworkError` recognise them by TYPE.
//  That is the #557 fix: swift-transformers wraps URL failures as
//  `HubClientError.downloadError(String)` / `.networkError(URLError)`, which the
//  NSURLErrorDomain-only predicate never saw.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8 (pure mapping pinned by
//  DownloadFailureCopyTests; the copy itself is Kev's call on first read).
//  Prior: none (new file).

import Foundation

/// How a download failed, in the four ways a person can act on.
public enum DownloadFailureKind: Equatable, Sendable {
    /// No route to the server, or it stalled: worth retrying.
    case offline
    /// The disk has no room for the file.
    case diskFull
    /// The bytes were refused (tampered, stale, or unreadable). `message` is the
    /// short, user-facing sentence. Never retried.
    case integrity(message: String)
    /// The user (or a newer pick) stopped it. Not a failure to report.
    case cancelled
    case unknown
}

/// An error type that knows how to classify itself. Conform from the module that owns
/// the type; return nil to defer to the generic URL / POSIX checks.
public protocol DownloadFailureClassifying: Error {
    var downloadFailureKind: DownloadFailureKind? { get }
}

public enum DownloadFailureCopy {
    /// Classify `error`: its own say first, then URL and file-system domains, walking
    /// `NSUnderlyingErrorKey` so a wrapped ENOSPC still reads as a full disk.
    public static func kind(of error: Error) -> DownloadFailureKind {
        if error is CancellationError { return .cancelled }
        if let own = (error as? any DownloadFailureClassifying)?.downloadFailureKind { return own }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return .cancelled }
        if isDiskFull(ns) { return .diskFull }
        if RetryPolicy.isTransientNetworkError(error) { return .offline }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            let inner = kind(of: underlying)
            if inner != .unknown { return inner }
        }
        return .unknown
    }

    /// One or two short sentences for the row. Always says what to do next.
    public static func message(for error: Error) -> String {
        switch kind(of: error) {
        case .offline:
            return String(localized: "Couldn't reach the download server. Check your connection and try again.")
        case .diskFull:
            return String(localized: "Not enough space on this Mac. Remove a download you don't use, or free some space, then try again.")
        case let .integrity(message):
            return message
        case .cancelled:
            return String(localized: "Download stopped.")
        case .unknown:
            let detail = error.localizedDescription
            return String(localized: "The download didn't finish (\(detail)). Try again in a moment.")
        }
    }

    /// `message(for:)` only when the error is one of the classes above (offline, disk, integrity),
    /// else nil. For a failure that is NOT necessarily a download (an MLX load can also fail
    /// on a bad config), where "the download didn't finish" would be a wrong guess and the
    /// system's own description is the better line.
    public static func knownMessage(for error: Error) -> String? {
        switch kind(of: error) {
        case .offline, .diskFull, .integrity: message(for: error)
        case .cancelled, .unknown: nil
        }
    }

    private static func isDiskFull(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(underlying) }
        return false
    }
}
