//
//  KokoroG2P+Bundled.swift
//  M1K3Kokoro
//
//  Loads the bundled misaki-gb pronunciation dictionary into a KokoroG2P. The resource
//  `g2p-en-gb.deflate` is `[UInt32 LE uncompressedSize][raw DEFLATE bytes]` (~1.5 MB
//  compressed from ~7.7 MB of `word<TAB>id,id,…` lines), inflated at load via Apple's
//  Compression framework — no third-party dependency.
//
//  Dictionary source: misaki (https://github.com/hexgrad/misaki), Apache License 2.0,
//  gb_gold.json + gb_silver.json merged — 197k British English pronunciations using
//  Kokoro's canonical single-token affricates/diphthongs.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-09, Confidence 0.7, Prior: Unknown
//  Review: Kev + claude-opus-4-6, 2026-06-21 — replaced espeak (GPL) dictionary with
//  misaki (Apache 2.0) for commercial shipping. Canonical Kokoro vocab: single-token
//  affricates (ʧ=133, ʤ=82) and diphthongs (A=24, I=25, Q=33, W=39, Y=41).
//  Confidence 0.85.
//

import Compression
import Foundation

public extension KokoroG2P {
    enum LoadError: Error {
        case resourceMissing(String)
        case inflateFailed
    }

    /// Resource basename of the bundled dictionary (without extension).
    static let bundledResource = "g2p-en-gb"

    /// Build a KokoroG2P from the bundled, compressed dictionary resource.
    static func bundled() throws -> KokoroG2P {
        guard let url = Bundle.module.url(forResource: bundledResource, withExtension: "deflate") else {
            throw LoadError.resourceMissing("\(bundledResource).deflate")
        }
        // Parse the inflated BYTES directly — materializing a 7.7 MB String and
        // Substring-splitting 197k lines measured 1.33 s of the voice tier's
        // load (2026-08-16), serial with the weights inside Loaded.init.
        let bytes = try inflateData(Data(contentsOf: url))
        return KokoroG2P(dictionary: parse(bytes))
    }

    /// Inflate `[UInt32 LE uncompressedSize][raw DEFLATE]` to its UTF-8 text.
    /// Kept for callers/tests that want the text; `bundled()` stays on bytes.
    internal static func inflate(_ data: Data) throws -> String {
        guard let text = try String(bytes: inflateData(data), encoding: .utf8) else {
            throw LoadError.inflateFailed
        }
        return text
    }

    /// Inflate `[UInt32 LE uncompressedSize][raw DEFLATE]` to its raw bytes.
    internal static func inflateData(_ data: Data) throws -> Data {
        guard data.count > 4 else { throw LoadError.inflateFailed }
        let size = Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16 | Int(data[3]) << 24
        let deflate = data.subdata(in: 4 ..< data.count)
        var destination = Data(count: size)
        let written = destination.withUnsafeMutableBytes { dst -> Int in
            deflate.withUnsafeBytes { src -> Int in
                // COMPRESSION_ZLIB in the buffer API = RAW DEFLATE (no zlib 2-byte header,
                // no Adler-32 trailer) — matches Python's zlib.compressobj(wbits=-15)
                // that produced this resource. The name is misleading.
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size,
                    src.bindMemory(to: UInt8.self).baseAddress!, deflate.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw LoadError.inflateFailed }
        return destination
    }

    /// Parse the `word<TAB>id,id,…` dictionary text into a lookup table. Lines
    /// without a tab or with no parseable ids are skipped. String entry point —
    /// kept as the test surface; `bundled()` parses bytes directly.
    internal static func parse(_ text: String) -> [String: [Int]] {
        parse(Data(text.utf8))
    }

    /// Byte-level parser — the load-time hot path. `String.split` +
    /// `Int(Substring)` over 197k lines measured 1.33 s (2026-08-16); walking
    /// the UTF-8 buffer once and hand-accumulating digits does the same job
    /// in a fraction of it. Semantics match the String version, pinned by
    /// `parseSkipsMalformed`: tab-less lines skip, empty ids skip, and an id
    /// segment containing any non-digit is dropped (the `Int.init` contract).
    internal static func parse(_ data: Data) -> [String: [Int]] {
        var dict = [String: [Int]](minimumCapacity: 210_000)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let newline: UInt8 = 0x0A, tab: UInt8 = 0x09, comma: UInt8 = 0x2C
            var index = 0
            let count = bytes.count
            while index < count {
                var lineEnd = index
                while lineEnd < count, bytes[lineEnd] != newline {
                    lineEnd += 1
                }
                var tabAt = index
                while tabAt < lineEnd, bytes[tabAt] != tab {
                    tabAt += 1
                }
                if tabAt > index, tabAt < lineEnd {
                    var ids: [Int] = []
                    var value = 0
                    var hasDigit = false
                    var segmentValid = true
                    var cursor = tabAt + 1
                    while cursor <= lineEnd {
                        let byte = cursor < lineEnd ? bytes[cursor] : comma
                        if byte >= 0x30, byte <= 0x39 {
                            value = value * 10 + Int(byte - 0x30)
                            hasDigit = true
                        } else if byte == comma {
                            if hasDigit, segmentValid { ids.append(value) }
                            value = 0
                            hasDigit = false
                            segmentValid = true
                        } else {
                            segmentValid = false
                        }
                        cursor += 1
                    }
                    if !ids.isEmpty {
                        let word = String(decoding: bytes[index ..< tabAt], as: UTF8.self)
                        dict[word] = ids
                    }
                }
                index = lineEnd + 1
            }
        }
        return dict
    }
}
