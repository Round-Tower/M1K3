//
//  AnalyzerLiveRecognitionIntegrationTests.swift
//  M1K3VoiceTests
//
//  The real SpeechAnalyzer path minus the microphone: `say` renders a paced
//  dictation, it is fed in 100 ms buffers at the tap's shape (48 kHz Float32
//  mono, so the converter runs), in real time, and the results go through the
//  same fold + endpoint the transcriber uses. Opt-in with the other heavy audio
//  suites (`M1K3_AUDIO_INTEGRATION=1`); needs the en-IE/en-US analyzer asset.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.8. Prior: Unknown.
//

import AVFoundation
import Foundation
@testable import M1K3Voice
import Synchronization
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_AUDIO_INTEGRATION"] == "1"), .serialized)
struct AnalyzerLiveRecognitionIntegrationTests {
    private final class Results: Sendable {
        let items = Mutex<[(String, Bool)]>([])
    }

    /// Two sentences with a 0.3 s pause inside the first and 1.6 s of quiet at the end.
    private func renderDictation() throws -> AVAudioPCMBuffer {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let out = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 20))
        func silence(_ seconds: Double) {
            let frames = AVAudioFrameCount(seconds * 48000)
            memset(out.floatChannelData![0].advanced(by: Int(out.frameLength)), 0, Int(frames) * 4)
            out.frameLength += frames
        }
        for (index, (text, gap)) in [("Remind me to call the landlord", 0.3), ("about the boiler on Wednesday.", 1.6)]
            .enumerated()
        {
            let file = dir.appendingPathComponent("\(index).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", "Daniel", "-o", file.path, text]
            try say.run()
            say.waitUntilExit()
            let source = try AVAudioFile(forReading: file)
            let read = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)))
            try source.read(into: read)
            let converter = try #require(AVAudioConverter(from: read.format, to: format))
            let converted = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(read.frameLength) * 48000 / read.format.sampleRate) + 64))
            var fed = false
            _ = converter.convert(to: converted, error: nil) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return read
            }
            memcpy(out.floatChannelData![0].advanced(by: Int(out.frameLength)), converted.floatChannelData![0], Int(converted.frameLength) * 4)
            out.frameLength += converted.frameLength
            silence(gap)
        }
        return out
    }

    @Test("dictation: one final with the whole sentence, ended by the endpoint after the real pause")
    func dictationEndsOnce() async throws {
        let audio = try renderDictation()
        let results = Results()
        let session = try #require(await AnalyzerLiveRecognition.start(
            locale: Locale(identifier: "en-IE"),
            onResult: { text, isFinal in results.items.withLock { $0.append((text, isFinal)) } },
            onError: { Issue.record("analyzer error: \($0)") }
        ), "SpeechAnalyzer unavailable (asset not installed?)")

        var fold = AnalyzerTranscriptFold(finality: .endsListen)
        var endpoint = AnalyzerEndpoint(finality: .endsListen)
        var seen = 0
        var endedAt: Double?
        let chunk = 4800
        var offset = 0
        while offset < Int(audio.frameLength), endedAt == nil {
            let count = min(chunk, Int(audio.frameLength) - offset)
            let piece = try #require(AVAudioPCMBuffer(pcmFormat: audio.format, frameCapacity: AVAudioFrameCount(count)))
            try memcpy(#require(piece.floatChannelData?[0]), #require(audio.floatChannelData?[0].advanced(by: offset)), count * 4)
            piece.frameLength = AVAudioFrameCount(count)
            offset += count
            try endpoint.audio(rms: AnalyzerEndpoint.rms(Array(UnsafeBufferPointer(start: #require(piece.floatChannelData?[0]), count: count))), seconds: 0.1)
            session.append(piece)
            try await Task.sleep(for: .milliseconds(100))
            let fresh = results.items.withLock { Array($0.dropFirst(seen)) }
            seen += fresh.count
            for (text, isFinal) in fresh {
                _ = fold.ingest(text: text, isFinal: isFinal)
                endpoint.result(isFinal: isFinal, hasText: fold.hasText)
            }
            if endpoint.shouldEnd { endedAt = Double(offset) / 48000 }
        }
        session.stop()

        let closing = try #require(fold.closingSegment())
        print("[analyzer-it] ended at \(endedAt ?? -1)s: \(closing.text)")
        #expect(endedAt != nil, "the endpoint should end the listen inside the trailing quiet")
        let lower = closing.text.lowercased()
        #expect(lower.contains("landlord") && lower.contains("wednesday"),
                "the 0.3 s pause must not have cut the dictation: \(closing.text)")
    }
}
