//
//  TextFragmentURL.swift
//  M1K3Preview
//
//  Builds the `#:~:text=` form of a URL (WICG Text Fragments, supported by WebKit), so a page
//  opened from a spoken quote scrolls to the passage and highlights it (#839). Pure: no UI, no
//  network. A quote that is not on the page costs nothing: the page opens, just without a
//  highlight. Only http(s) URLs come back at all; anything else is refused here so a caller
//  cannot launder a `file:` or `javascript:` URL through the builder.
//
//  Escaping is the spec's: percent-encode everything outside the unreserved set, and the
//  three characters the directive syntax itself uses (`-`, `&`, `,`) are encoded too.
//  A quote longer than `maxExactLength` becomes the `start,end` range form (its first and last
//  few words), which highlights the whole span without carrying it in the URL.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.85 (escaping pinned against the
//  spec's rules; whether WebKit's WKWebView highlights on a programmatic load is a
//  verify-on-device check). Prior: none (new file).

import Foundation

public enum TextFragmentURL {
    /// Longest exact quote carried whole. Past it the range form takes over.
    public static let maxExactLength = 240
    /// Words kept at each end of a range-form quote.
    public static let rangeEdgeWords = 4

    private static let directive = ":~:text="

    /// `url` with a text fragment for `quote`, or `url` unchanged when there is nothing to
    /// highlight. nil when `url` is not http(s).
    public static func url(for url: URL, quote: String?) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let quote else { return url }
        let words = quote.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.percentEncodedFragment = directive + encodedBody(words: words)
        return parts.url ?? url
    }

    private static func encodedBody(words: [String]) -> String {
        let joined = words.joined(separator: " ")
        if joined.count <= maxExactLength { return escape(joined) }
        if words.count >= rangeEdgeWords * 2 {
            let start = words.prefix(rangeEdgeWords).joined(separator: " ")
            let end = words.suffix(rangeEdgeWords).joined(separator: " ")
            // Edges that are themselves huge tokens still get cut, so the URL stays small.
            return escape(String(start.prefix(maxExactLength / 2))) + "," + escape(String(end.suffix(maxExactLength / 2)))
        }
        return escape(String(joined.prefix(maxExactLength)))
    }

    /// Percent-encode as UTF-8 everything but ASCII letters, digits, `.`, `_` and `~`.
    /// That keeps `-`, `&` and `,` (the directive's own delimiters) encoded.
    private static func escape(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
