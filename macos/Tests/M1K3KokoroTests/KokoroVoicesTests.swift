import Foundation
@testable import M1K3Kokoro
import Testing

struct KokoroVoicesTests {
    /// Build a minimal STORED `.npz` containing one (510,1,256) float32 voice array.
    private func makeNPZ(voice: String, floats: [Float]) -> Data {
        // --- .npy (version 1.0) ---
        var npy = Data([0x93])
        npy.append("NUMPY".data(using: .ascii)!)
        npy.append(contentsOf: [0x01, 0x00]) // version
        var header = "{'descr': '<f4', 'fortran_order': False, 'shape': (510, 1, 256), }"
        let unpadded = 10 + header.count + 1 // +1 for trailing \n
        let pad = (64 - unpadded % 64) % 64
        header += String(repeating: " ", count: pad) + "\n"
        npy.append(contentsOf: [UInt8(header.count & 0xFF), UInt8(header.count >> 8)])
        npy.append(header.data(using: .ascii)!)
        for value in floats {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { npy.append(contentsOf: $0) }
        }
        /// --- ZIP STORED local file header ---
        func le32(_ value: Int) -> [UInt8] {
            [0, 8, 16, 24].map { UInt8((value >> $0) & 0xFF) }
        }
        func le16(_ value: Int) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
        }
        let name = (voice + ".npy").data(using: .ascii)!
        var zip = Data([0x50, 0x4B, 0x03, 0x04, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        zip.append(contentsOf: le32(npy.count)) // compressed size
        zip.append(contentsOf: le32(npy.count)) // uncompressed size
        zip.append(contentsOf: le16(name.count))
        zip.append(contentsOf: le16(0)) // extra len
        zip.append(name)
        zip.append(npy)
        return zip
    }

    @Test("extracts the correct 256-float style row for a token count")
    func extractsRow() throws {
        // Fill so the float at flat index k == Float(k); row R then starts at R*256.
        let floats = (0 ..< (KokoroVoices.rows * KokoroVoices.styleWidth)).map { Float($0) }
        let voices = try KokoroVoices(npzData: makeNPZ(voice: "tv", floats: floats))
        #expect(voices.voiceNames == ["tv"])
        let style = try voices.style(voice: "tv", tokenCount: 14)
        #expect(style.count == 256)
        #expect(style[0] == Float(14 * 256))
        #expect(style[255] == Float(14 * 256 + 255))
    }

    @Test("clamps an over-long token count to the last row")
    func clampsRow() throws {
        let floats = (0 ..< (KokoroVoices.rows * KokoroVoices.styleWidth)).map { Float($0) }
        let voices = try KokoroVoices(npzData: makeNPZ(voice: "tv", floats: floats))
        let style = try voices.style(voice: "tv", tokenCount: 9999)
        #expect(style[0] == Float(509 * 256)) // clamped to row 509
    }

    @Test("throws for an unknown voice")
    func unknownVoice() throws {
        let floats = [Float](repeating: 0, count: KokoroVoices.rows * KokoroVoices.styleWidth)
        let voices = try KokoroVoices(npzData: makeNPZ(voice: "tv", floats: floats))
        #expect(throws: KokoroVoices.VoicesError.self) {
            _ = try voices.style(voice: "ghost", tokenCount: 1)
        }
    }

    @Test("throws (does not trap) on a truncated file that is only the ZIP signature")
    func truncatedSignatureOnly() {
        #expect(throws: KokoroVoices.VoicesError.self) {
            _ = try KokoroVoices(npzData: Data([0x50, 0x4B, 0x03, 0x04]))
        }
    }

    @Test("throws (does not trap) when the local header is cut off mid-field")
    func truncatedHeader() {
        // Signature + 10 bytes — fewer than the 30-byte fixed local header, so
        // reading compSize at cursor+18 would run past the end.
        var data = Data([0x50, 0x4B, 0x03, 0x04])
        data.append(contentsOf: [UInt8](repeating: 0, count: 10))
        #expect(throws: KokoroVoices.VoicesError.self) {
            _ = try KokoroVoices(npzData: data)
        }
    }

    @Test("throws (does not trap) when the name length runs past the buffer")
    func truncatedName() {
        // A complete 30-byte header claiming a 200-byte name, with no name bytes.
        var data = Data([0x50, 0x4B, 0x03, 0x04, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0]) // comp + uncomp size (bytes 18…25)
        data.append(contentsOf: [200, 0]) // name length = 200 (bytes 26…27)
        data.append(contentsOf: [0, 0]) // extra length = 0 (bytes 28…29)
        #expect(throws: KokoroVoices.VoicesError.self) {
            _ = try KokoroVoices(npzData: data)
        }
    }

    @Test("reads the real voices-v1.0.bin if present (bm_daniel style[14] matches oracle)")
    func realFileIfPresent() throws {
        // Derive models/kokoro from this file's location (…/macos/Tests/M1K3KokoroTests/<file>).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("models/kokoro/voices-v1.0.bin")
        guard FileManager.default.fileExists(atPath: url.path) else { return } // skip in CI
        let voices = try KokoroVoices(contentsOf: url)
        #expect(voices.voiceNames.count == 54)
        let style = try voices.style(voice: "bm_daniel", tokenCount: 14)
        // Oracle (numpy): [0.03172958, 0.12655608, -0.05771561, 0.2539448]
        #expect(abs(style[0] - 0.03172958) < 1e-6)
        #expect(abs(style[1] - 0.12655608) < 1e-6)
        #expect(abs(style[3] - 0.2539448) < 1e-6)
    }
}
