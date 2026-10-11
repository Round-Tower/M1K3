//
//  Retry.swift
//  M1K3Inference
//
//  Retry an async operation on TRANSIENT failures with exponential backoff.
//  Built for the model-weights download: a single HuggingFace CDN timeout
//  (NSURLErrorTimedOut, seen at ⌘R) would otherwise kill a whole chat turn,
//  even though the download is resumable and the stall is usually momentary.
//  Wrapping the load means each retry continues the cached partial download.
//
//  Pure + Metal-free, so the retry contract is proven under `swift test` rather
//  than stuck behind the MLX launch wall.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-10, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-11 — #557: `isTransientNetworkError` defers to a
//  `DownloadFailureClassifying` error's own verdict, so Hub's wrapped URL errors retry.
//  Confidence 0.85 (pure, pinned by DownloadFailureCopyTests + DownloadErrorsTests).

import Foundation

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: Duration

    public init(maxAttempts: Int = 3, baseDelay: Duration = .seconds(2)) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
    }

    /// Exponential backoff: `baseDelay * 2^(attempt-1)`, with `attempt` 1-based.
    func delay(forAttempt attempt: Int) -> Duration {
        let exponent = max(0, attempt - 1)
        return baseDelay * Double(1 << exponent)
    }

    /// True for transient network failures worth retrying — timeouts, dropped
    /// connections, momentary DNS/host trouble — but NOT client errors (bad URL)
    /// or cancellation. `URLError` bridges to `NSURLErrorDomain`, so matching the
    /// domain + code set covers both the Foundation and CFNetwork shapes.
    public static func isTransientNetworkError(_ error: Error) -> Bool {
        // A module that owns the error type classifies it by TYPE (#557: Hub wraps URL
        // failures as `downloadError(String)` / `networkError(URLError)`, which the
        // domain check below never saw). Its verdict is final when it gives one.
        if let own = (error as? any DownloadFailureClassifying)?.downloadFailureKind {
            return own == .offline
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let retryable: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable,
            NSURLErrorNotConnectedToInternet,
        ]
        return retryable.contains(nsError.code)
    }
}

/// Run `operation`, retrying on `isRetryable` errors up to the policy's attempts
/// with exponential backoff. Non-retryable errors (and cancellation) propagate
/// immediately; the last error is thrown once attempts are exhausted. `onRetry`
/// fires once per retry, before the backoff sleep, for logging/UI.
public func withRetry<T: Sendable>(
    policy: RetryPolicy = RetryPolicy(),
    isRetryable: @Sendable (Error) -> Bool = RetryPolicy.isTransientNetworkError,
    onRetry: @Sendable (_ attempt: Int, _ error: Error) -> Void = { _, _ in },
    operation: @Sendable () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch {
            guard attempt < policy.maxAttempts, isRetryable(error) else { throw error }
            onRetry(attempt, error)
            try await Task.sleep(for: policy.delay(forAttempt: attempt))
            attempt += 1
        }
    }
}
