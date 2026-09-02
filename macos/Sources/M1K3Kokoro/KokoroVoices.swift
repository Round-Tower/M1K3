//
//  KokoroVoices.swift
//  M1K3Kokoro
//
//  Reads the Kokoro voice-style pack `voices-v1.0.bin` — a numpy `.npz` (a ZIP of one
//  `<voice>.npy` per voice, each a float32 array of shape (510, 1, 256): one 256-d
//  style vector per possible phoneme-token length). The model's `style` input is
//  `voice[tokenCount]` → the [1, 256] row indexed by the UNWRAPPED token count.
//
//  The npz stores entries UNCOMPRESSED (STORED), so this is a plain ZIP local-header
//  walk + npy-header parse + row slice — no inflate needed. CRC is not verified (the
//  file is an integrity-checked download, and we only read, never write).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-09, Confidence 0.7, Prior: Unknown
//

import Foundation

public struct KokoroVoices: Sendable {
    public enum VoicesError: Error {
        case notNPZ
        case voiceNotFound(String)
        case corruptData
    }

    /// Rows per voice array (max phoneme-token length + 1) and style width.
    public static let rows = 510
    public static let styleWidth = 256

    private let data: Data
    /// voiceName (without `.npy`) → byte offset where that entry's float32 data begins.
    private let dataOffsets: [String: Int]

    public init(npzData: Data) throws {
        data = npzData
        dataOffsets = try Self.index(npzData)
        if dataOffsets.isEmpty { throw VoicesError.notNPZ }
    }

    public init(contentsOf url: URL) throws {
        try self.init(npzData: Data(contentsOf: url))
    }

    public var voiceNames: [String] {
        dataOffsets.keys.sorted()
    }

    /// The 256-float style vector for `voice` at `tokenCount` (clamped to a valid row).
    public func style(voice: String, tokenCount: Int) throws -> [Float] {
        guard let base = dataOffsets[voice] else { throw VoicesError.voiceNotFound(voice) }
        let row = max(0, min(tokenCount, Self.rows - 1))
        let start = base + row * Self.styleWidth * 4
        // Guard against a truncated/corrupt download — read past the end would crash.
        guard start + Self.styleWidth * 4 <= data.count else { throw VoicesError.corruptData }
        var out = [Float](repeating: 0, count: Self.styleWidth)
        for column in 0 ..< Self.styleWidth {
            let off = start + column * 4
            let bits = UInt32(data[off]) | UInt32(data[off + 1]) << 8
                | UInt32(data[off + 2]) << 16 | UInt32(data[off + 3]) << 24
            out[column] = Float(bitPattern: bits)
        }
        return out
    }

    // MARK: - ZIP / NPY parsing

    /// Walk STORED ZIP local file headers, mapping each `<name>.npy` to the byte offset
    /// of its numpy data (past both the ZIP header and the npy header).
    private static func index(_ data: Data) throws -> [String: Int] {
        var offsets: [String: Int] = [:]
        let count = data.count
        var cursor = 0
        func u16(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8
                | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }

        while cursor + 4 <= count {
            // Local file header signature 'PK\3\4'. Anything else (e.g. central dir
            // 'PK\1\2') ends the entry stream.
            guard data[cursor] == 0x50, data[cursor + 1] == 0x4B,
                  data[cursor + 2] == 0x03, data[cursor + 3] == 0x04
            else { break }
            // The fixed local-file header is 30 bytes; a truncated/corrupt file
            // that ends inside one must stop the walk, not read past the end
            // (the field reads below would trap on a short buffer).
            guard cursor + 30 <= count else { break }
            var compSize = u32(cursor + 18)
            let nameLen = u16(cursor + 26)
            let extraLen = u16(cursor + 28)
            let nameStart = cursor + 30
            guard nameStart + nameLen <= count else { break }
            let name = String(bytes: data[nameStart ..< nameStart + nameLen], encoding: .utf8) ?? ""
            let extraStart = nameStart + nameLen
            // ZIP64: numpy's savez streams entries, so the local header sizes are the
            // 0xFFFFFFFF sentinel and the real 64-bit sizes live in the extra field
            // (header id 0x0001: uncompressedSize then compressedSize).
            if compSize == 0xFFFF_FFFF {
                compSize = zip64CompSize(data, extraStart: extraStart, extraLen: extraLen) ?? compSize
            }
            let entryData = extraStart + extraLen
            if name.hasSuffix(".npy"), let npyData = npyDataOffset(data, at: entryData) {
                offsets[String(name.dropLast(4))] = npyData
            }
            cursor = entryData + compSize
        }
        return offsets
    }

    /// Read the ZIP64 extended-information extra field (id 0x0001). For a streamed local
    /// header both sizes are present, in order [uncompressedSize, compressedSize].
    private static func zip64CompSize(_ data: Data, extraStart: Int, extraLen: Int) -> Int? {
        var cursor = extraStart
        // Never read past the real buffer even if extraLen (corrupt/tampered) claims more.
        let end = min(extraStart + extraLen, data.count)
        while cursor + 4 <= end {
            let fieldID = Int(data[cursor]) | Int(data[cursor + 1]) << 8
            let size = Int(data[cursor + 2]) | Int(data[cursor + 3]) << 8
            if fieldID == 0x0001, size >= 16 {
                let compAt = cursor + 4 + 8 // skip uncompressedSize, read compressedSize
                guard compAt + 8 <= end else { return nil }
                return (0 ..< 8).reduce(0) { $0 | Int(data[compAt + $1]) << (8 * $1) }
            }
            cursor += 4 + size
        }
        return nil
    }

    /// Given the start of a `.npy` blob, validate the magic and return the offset where
    /// the array data begins (`10 + headerLen`).
    private static func npyDataOffset(_ data: Data, at start: Int) -> Int? {
        guard start + 10 <= data.count,
              data[start] == 0x93,
              data[start + 1] == 0x4E, data[start + 2] == 0x55, data[start + 3] == 0x4D,
              data[start + 4] == 0x50, data[start + 5] == 0x59 // \x93 N U M P Y
        else { return nil }
        let headerLen = Int(data[start + 8]) | Int(data[start + 9]) << 8 // version 1.0: uint16
        return start + 10 + headerLen
    }
}
