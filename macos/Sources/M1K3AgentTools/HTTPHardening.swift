//
//  HTTPHardening.swift
//  M1K3AgentTools
//
//  Robustness primitives shared by the web-reaching tools, all pure + testable:
//   • HTTPStatus.classify — turn a status code into ok / transient / client /
//     server, so rate-limit detection no longer depends on string-matching the
//     challenge HTML (DDG can change that markup; 202/429 it can't fake away).
//   • BodyDecoder.decode — honour the response charset (header → <meta> → UTF-8
//     → Latin-1), so a non-UTF8 page is read instead of silently becoming "".
//   • RetryingHTTPFetcher — one bounded retry on a transient failure (timeout,
//     dropped connection, 429/503), so a single blip doesn't end the agent turn.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-10 — `.redirect` for 3xx (#266 review 3): with the fetcher's
//  RedirectGate able to decline a hop, a 3xx can reach a tool, and "ok" made it read the stub as a page.

import Foundation

// MARK: - Status classification

public enum HTTPStatusClass: Sendable, Equatable {
    case ok // 2xx (bar the throttle codes below)
    case transient // retry may help: 202 (DDG throttle), 429, 502/503/504
    case redirect // 3xx that came back as the FINAL response: the RedirectGate declined the hop (#266)
    case clientError // 4xx — don't retry
    case serverError // other 5xx — don't retry
}

public enum HTTPStatus {
    public static func classify(_ status: Int) -> HTTPStatusClass {
        switch status {
        // 202 Accepted is DDG's "anomaly" throttle in this codebase, not success.
        case 202, 429, 502, 503, 504: return .transient
        case 200 ... 299: return .ok
        // URLSession follows 3xx itself — one that reaches a caller is a hop the
        // RedirectGate refused (private / unresolvable target). Not a page.
        case 300 ... 399: return .redirect
        case 400 ... 499: return .clientError
        case 500 ... 599: return .serverError
        default: return .ok // 1xx / unknown: treat as usable
        }
    }

    /// Thrown URLErrors worth one retry (a momentary network blip).
    static func isTransient(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}

// MARK: - Charset-aware body decoding

public enum BodyDecoder {
    /// Decode an HTTP body to text, honouring (in order): a UTF-8 BOM, the
    /// `Content-Type` charset, valid UTF-8, a `<meta charset>` declaration, and
    /// finally Latin-1 — which never fails, so we never silently return "".
    public static func decode(_ data: Data, contentType: String?) -> String {
        guard !data.isEmpty else { return "" }

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if let name = charsetName(fromContentType: contentType),
           let encoding = encoding(forCharset: name),
           let text = String(data: data, encoding: encoding)
        {
            return text
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        // Read the bytes loosely to find a <meta charset> the header omitted.
        let preview = String(decoding: data.prefix(2048), as: UTF8.self)
        if let name = metaCharset(in: preview),
           let encoding = encoding(forCharset: name),
           encoding != .utf8,
           let text = String(data: data, encoding: encoding)
        {
            return text
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func charsetName(fromContentType contentType: String?) -> String? {
        guard let contentType, let range = contentType.range(of: "charset=", options: .caseInsensitive) else {
            return nil
        }
        let raw = contentType[range.upperBound...]
            .prefix { $0 != ";" && $0 != " " }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).nilIfEmpty
    }

    static func metaCharset(in html: String) -> String? {
        // String pattern (not a regex literal) — the swiftformat hook strips
        // capture-group parens inside /…/ literals; it leaves string patterns alone.
        let pattern = "(?i)<meta[^>]+charset[\\s]*=[\\s]*[\"']?([\\w-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[captured])
    }

    static func encoding(forCharset name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Retry decorator

/// Wraps any fetcher with one bounded retry on a transient failure. The backoff
/// is injectable so tests don't actually sleep.
public struct RetryingHTTPFetcher: HTTPFetching {
    private let inner: any HTTPFetching
    private let maxAttempts: Int
    /// Throwing so a CancellationError from the sleep propagates — a cancelled
    /// turn must not fire a spurious retry.
    private let backoff: @Sendable (Int) async throws -> Void

    /// `maxAttempts` is clamped to ≥1 (so a single attempt is the floor); the
    /// default of 2 means "try once, retry once on a transient failure".
    public init(
        _ inner: any HTTPFetching,
        maxAttempts: Int = 2,
        backoff: @escaping @Sendable (Int) async throws -> Void = { attempt in
            try await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
        }
    ) {
        self.inner = inner
        self.maxAttempts = max(1, maxAttempts)
        self.backoff = backoff
    }

    public func fetch(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        var attempt = 1
        while true {
            let isLast = attempt >= maxAttempts
            do {
                let result = try await inner.fetch(request)
                if !isLast, HTTPStatus.classify(result.response.statusCode) == .transient {
                    try await backoff(attempt)
                    attempt += 1
                    continue
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !isLast, HTTPStatus.isTransient(error) else { throw error }
                try await backoff(attempt)
                attempt += 1
            }
        }
    }

    /// The production fetcher the web tools default to: a real URLSession with a
    /// 12s timeout, wrapped in one bounded retry.
    public static let production = RetryingHTTPFetcher(URLSessionHTTPFetcher())
}
