import Foundation
@testable import M1K3Kokoro
import Testing

/// End-to-end integration smoke test for the FULL in-package neural path
/// (KokoroG2P → KokoroVoices → MLX inference). Guarded on BOTH the staged model
/// files AND `M1K3_MLX_INTEGRATION=1` (the house convention for real-MLX tests,
/// `../M1K3MLXTests/MLXEmbeddingServiceTests.swift`) — never just file presence.
///
/// ⚠️ 2026-07-18 (the ONNX→MLX backend swap): when the guard passes, this suite
/// does NOT run safely under CLI `swift test` — MLX **aborts the whole process**
/// ("Failed to load the default metallib", no catchable Swift error) because the
/// xctest runner isn't an .app bundle (the same known limit
/// `MLXEmbeddingServiceTests`/`MLXBrainProviderTests` document, but WORSE here:
/// those two only fail their own test; this one takes the entire `swift test`
/// run down with it). That is exactly why the env-var gate was ADDED here
/// (verified: with the flag off, `swift test --parallel` stayed green at
/// 1982/288 even with real weights staged at `models/kokoro/`) — file presence
/// alone used to be enough to run this suite under the old ONNX backend (ORT
/// has no metallib wall), so a developer's local `models/kokoro/` from before
/// this port would otherwise silently start crashing every `swift test` run.
/// Real verification for this suite's assertions was done via a standalone
/// `swift run` executable with the mlx-swift Cmlx.bundle copied beside the
/// binary (see KokoroSynthesizer.swift's 2026-07-18 review note and the PR
/// body) — left staged-file-gated here so it stays the obvious place to look,
/// and so `M1K3_MLX_INTEGRATION=1 swift test --filter KokoroSynthesizerTests`
/// (run alone, never in the full suite) is the one-liner that reproduces it.
struct KokoroSynthesizerTests {
    /// Repo's `models/kokoro`, derived from this file's location so the guarded test
    /// runs on any checkout (…/macos/Tests/M1K3KokoroTests/<thisFile>).
    private var modelDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("models/kokoro")
    }

    private var staged: Bool {
        guard ProcessInfo.processInfo.environment["M1K3_MLX_INTEGRATION"] == "1" else { return false }
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: modelDir.appendingPathComponent("config.json").path)
            && fileManager.fileExists(atPath: modelDir.appendingPathComponent("model.safetensors").path)
            && fileManager.fileExists(atPath: modelDir.appendingPathComponent("voices-v1.0.bin").path)
    }

    @Test("full pipeline synthesizes plausible speech for a sentence")
    func synthesizesPlausibleAudio() async throws {
        guard staged else { return } // skipped in CI, and skipped locally unless M1K3_MLX_INTEGRATION=1
        let synth = KokoroSynthesizer(modelDirectory: modelDir, voice: "bm_daniel")
        let pcm = try await synth.synthesize(text: "Hello world. This is M1K3 speaking.")

        // Plausible speech: non-empty, several hundred ms, energy in a speech range
        // (not silence, not clipped noise).
        #expect(pcm.count > 20000) // > ~0.8s @ 24kHz
        let rms = (pcm.reduce(0) { $0 + $1 * $1 } / Float(pcm.count)).squareRoot()
        #expect(rms > 0.01)
        #expect(rms < 0.5)
        let peak = pcm.map(abs).max() ?? 0
        #expect(peak <= 1.0)

        // Drop a WAV in the repo's scratch fixtures (best-effort) to listen to the path.
        let scratch = modelDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scratch/kokoro-spike/fixtures")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        writeWav(pcm, sampleRate: 24000, to: scratch.appendingPathComponent("integrated_hello.wav").path)
    }

    @Test("empty/whitespace text yields no audio (caller falls back)")
    func emptyTextNoAudio() async throws {
        guard staged else { return }
        let synth = KokoroSynthesizer(modelDirectory: modelDir)
        let pcm = try await synth.synthesize(text: "   ")
        #expect(pcm.isEmpty)
    }

    @Test("long text is chunked, never truncated — duration scales with length")
    func longTextNotTruncated() async throws {
        guard staged else { return } // skipped in CI
        let sentence = "The quick brown fox jumps over the lazy dog near the quiet river bank. "
        let short = String(repeating: sentence, count: 2)
        let long = String(repeating: sentence, count: 12) // far beyond 510 phoneme tokens

        let synth = KokoroSynthesizer(modelDirectory: modelDir, voice: "bm_daniel")
        let shortPCM = try await synth.synthesize(text: short)

        var chunkCount = 0
        var longSamples = 0
        var lastRangeStart = -1
        var timelineWordCount = 0
        for try await chunk in synth.synthesizeStream(text: long) {
            chunkCount += 1
            longSamples += chunk.samples.count
            timelineWordCount += chunk.timeline.words.count
            #expect(chunk.timeline.text == long)
            // Word ranges advance monotonically across chunks (full-string offsets).
            if let first = chunk.timeline.words.first {
                #expect(first.textRange.lowerBound > lastRangeStart)
                lastRangeStart = first.textRange.lowerBound
            }
        }

        #expect(chunkCount > 1) // the old path produced exactly one capped buffer
        // 6× the text must yield well over 3× the audio (the truncation bug capped it
        // near-constant regardless of input length).
        #expect(longSamples > shortPCM.count * 3)
        // Every word of every repetition is timed — derive the per-sentence
        // count from the string so editing the fixture can't silently miscount.
        let wordsPerSentence = sentence.split(separator: " ").count
        #expect(timelineWordCount == 12 * wordsPerSentence)
    }
}

private func writeWav(_ samples: [Float], sampleRate: Int, to path: String) {
    var data = Data()
    let dataSize = samples.count * 2
    func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
    func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
    data.append("RIFF".data(using: .ascii)!); data.append(le32(UInt32(36 + dataSize)))
    data.append("WAVE".data(using: .ascii)!); data.append("fmt ".data(using: .ascii)!)
    data.append(le32(16)); data.append(le16(1)); data.append(le16(1))
    data.append(le32(UInt32(sampleRate))); data.append(le32(UInt32(sampleRate * 2)))
    data.append(le16(2)); data.append(le16(16))
    data.append("data".data(using: .ascii)!); data.append(le32(UInt32(dataSize)))
    for sample in samples {
        let clamped = max(-1, min(1, sample))
        data.append(le16(UInt16(bitPattern: Int16(clamped * 32767))))
    }
    try? data.write(to: URL(fileURLWithPath: path))
}
