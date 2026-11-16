//
//  AppleBufferTranscriber.swift
//  M1K3Voice
//
//  The polish pass's engine (#852): one finished utterance, already in memory, through
//  SpeechTranscriber in ACCURATE mode (no `.fastResults`: 8.9% WER against the shipped fast mode's
//  10.7%, docs/evals/2026-10-15-stt.md; a file pass costs about 0.18 s). The buffer gets a second of
//  trailing silence, as AppleFileTranscriber's clips do, because the recogniser drops the last words
//  of audio that ends on speech. Apple's analyzer only (never WhisperKit: Whisper is an optional
//  download), on-device by construction, and nothing touches disk.
//
//  Like AppleFileTranscriber it never downloads an asset behind the user's back: a missing locale
//  asset throws and the caller keeps the live text. Verify-by-launch (a real Speech asset); the
//  eval's "polish" arm (SpeechToTextEvalTests) drives this same function on recorded clips.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-16, Confidence 0.7 (the calls match the SDK and the
//  file-fed pass; run by the eval, not yet on a live turn). Prior: Unknown.
//  Review: claude-opus-5-5, 2026-11-16 (code-quality review fold, #852) — the analyzer is finished
//  (`cancelAndFinishNow`) on every exit, cancelled or thrown; `analyzerBuffer` refuses a conversion
//  that returns under 90% of the expected frames, and is pinned by tests (rates, empty, sine).

import AVFoundation
import Foundation
import Speech

public enum AppleBufferTranscriber {
    public enum Failure: Error, Equatable {
        case unsupportedLocale(String)
        case noAnalyzerFormat
        case unusableAudio
    }

    public static func transcribe(
        _ audio: UtteranceAudio,
        locale: Locale,
        trailingSilenceSeconds: Double = VoicePolishPolicy.trailingSilenceSeconds
    ) async throws -> String {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: []
        )
        try await AppleFileTranscriber.requireInstalled(transcriber, locale: supported)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noAnalyzerFormat
        }
        let buffer = try analyzerBuffer(
            audio.padded(trailingSilenceSeconds: trailingSilenceSeconds), sampleRate: audio.sampleRate, format: format
        )
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        input.yield(AnalyzerInput(buffer: buffer))
        input.finish()

        let collected = Task {
            try await transcriber.results.reduce(into: [String]()) { $0.append(String($1.text.characters)) }
        }
        defer { collected.cancel() } // a throwing analyze, or a cancelled pass, must not leave the reader running
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let last = try await analyzer.analyzeSequence(stream) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try AppleFileTranscriber.join(await collected.value)
        } catch {
            // Cancelled by the time budget, or thrown: the analyzer must not outlive the pass.
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// The samples as one buffer in the analyzer's own format (the live path converts per tap
    /// buffer; here the whole utterance converts at once).
    static func analyzerBuffer(_ samples: [Float], sampleRate: Double, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard !samples.isEmpty,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0]
        else { throw Failure.unusableAudio }
        samples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { channel.update(from: base, count: buffer.count) }
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        if source == format { return input }

        guard let converter = AVAudioConverter(from: source, to: format) else { throw Failure.unusableAudio }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw Failure.unusableAudio
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        // A converter that quietly returns a fraction of the audio would hand the analyzer a clipped
        // utterance and a plausible-looking transcript of its start: refuse it.
        let expected = Double(samples.count) * format.sampleRate / sampleRate
        guard status != .error, Double(output.frameLength) >= expected * 0.9 else {
            throw error ?? Failure.unusableAudio
        }
        return output
    }
}
