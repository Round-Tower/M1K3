//
//  AppleFileTranscriber.swift
//  M1K3Voice
//
//  A whole audio file through Apple's on-device speech modules, for the
//  speech-to-text eval (SpeechToTextEvalTests): the SpeechAnalyzer path voice
//  mode listens on (SpeechTranscriber, `.fastResults` as shipped or without it),
//  or DictationTranscriber, optionally with a vocabulary of contextual strings
//  (names M1K3 already knows). Final results only, joined in order.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.7 (Speech glue, run
//  by the gated eval only; the module options mirror AnalyzerLiveRecognition).
//  Prior: Unknown.
//  Review: claude-opus-5-5, 2026-10-15: every clip now ends on 1 s of silence
//  (withTrailingSilence): on Kev's corpus DictationTranscriber dropped the last words of 8/30
//  clips without it. Confidence 0.75.
//  Review: claude-opus-5-5, 2026-10-15: the copy goes in chunks, zeroes its silence
//  explicitly, takes an empty clip, and is deleted on any failure (code-quality-reviewer).

import AVFoundation
import Foundation
import Speech

public enum AppleFileTranscriber {
    public enum Module: Sendable, Equatable {
        /// SpeechTranscriber, the analyzer voice mode uses; `fast` is the shipped `.fastResults`.
        case speech(fast: Bool)
        /// DictationTranscriber, short-dictation preset.
        case dictation
    }

    public enum Failure: Error, Equatable {
        case unsupportedLocale(String)
        case assetNotInstalled(String)
        case unreadableAudio(String)
    }

    /// Silence fed after the clip, as a live mic keeps running after the speaker stops.
    public static let trailingSilenceSeconds = 1.0

    public static func transcribe(
        _ url: URL, locale: Locale, module: Module, vocabulary: [String] = []
    ) async throws -> String {
        let padded = try withTrailingSilence(url, seconds: trailingSilenceSeconds)
        defer { try? FileManager.default.removeItem(at: padded) }
        let file = try AVAudioFile(forReading: padded)
        let context = AnalysisContext()
        if !vocabulary.isEmpty { context.contextualStrings[.general] = vocabulary }
        switch module {
        case let .speech(fast):
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw Failure.unsupportedLocale(locale.identifier)
            }
            let transcriber = SpeechTranscriber(
                locale: supported, transcriptionOptions: [], reportingOptions: fast ? [.fastResults] : [],
                attributeOptions: []
            )
            try await requireInstalled(transcriber, locale: supported)
            let collected = Task {
                try await transcriber.results.reduce(into: [String]()) { $0.append(String($1.text.characters)) }
            }
            try await analyze(file, modules: [transcriber], context: context)
            return try join(await collected.value)
        case .dictation:
            guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                throw Failure.unsupportedLocale(locale.identifier)
            }
            let transcriber = DictationTranscriber(locale: supported, preset: .shortDictation)
            try await requireInstalled(transcriber, locale: supported)
            let collected = Task {
                try await transcriber.results.reduce(into: [String]()) { $0.append(String($1.text.characters)) }
            }
            try await analyze(file, modules: [transcriber], context: context)
            return try join(await collected.value)
        }
    }

    /// Context first, then the file, then finish: the file initializer's `analysisContext:`
    /// left the output byte-identical with and without a vocabulary (2026-10-15).
    private static func analyze(
        _ file: AVAudioFile, modules: [any SpeechModule], context: AnalysisContext
    ) async throws {
        let analyzer = SpeechAnalyzer(modules: modules)
        if !context.contextualStrings.isEmpty { try await analyzer.setContext(context) }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
    }

    /// An eval never downloads behind the user's back: a missing asset fails the arm, named.
    /// `installedLocales` first: `status(forModules:)` reads `.supported` in a test process
    /// with the locale installed and working (AnalyzerLiveRecognition, 2026-09-26).
    private static func requireInstalled(_ module: any SpeechModule, locale: Locale) async throws {
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier }) { return }
        if await AssetInventory.status(forModules: [module]) == .installed { return }
        throw Failure.assetNotInstalled(locale.identifier)
    }

    /// A temporary copy of the clip with silence after it. DictationTranscriber drops the last
    /// words of a clip that ends on speech (Kev's corpus, 2026-10-15: "at half past [eight]",
    /// "what I [said]"; finalizing through the end of input didn't help, 1 s of silence did).
    static func withTrailingSilence(_ url: URL, seconds: Double) throws -> URL {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-stt-\(UUID().uuidString).caf")
        do {
            // The copy is a voice: it never outlives a failure.
            let sink = try AVAudioFile(forWriting: out, settings: format.settings)
            let chunk: AVAudioFrameCount = 16384
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw Failure.unreadableAudio(url.lastPathComponent)
            }
            while source.framePosition < source.length {
                try source.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                try sink.write(from: buffer)
            }
            var silent = AVAudioFrameCount(seconds * format.sampleRate)
            while silent > 0 {
                buffer.frameLength = min(chunk, silent)
                for channel in 0 ..< Int(format.channelCount) {
                    buffer.floatChannelData.map { memset($0[channel], 0, Int(buffer.frameLength) * 4) }
                }
                try sink.write(from: buffer)
                silent -= buffer.frameLength
            }
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    private static func join(_ segments: [String]) -> String {
        segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
