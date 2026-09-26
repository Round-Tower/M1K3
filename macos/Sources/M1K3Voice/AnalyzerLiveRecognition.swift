//
//  AnalyzerLiveRecognition.swift
//  M1K3Voice
//
//  One live SpeechAnalyzer + SpeechTranscriber session for AppleSpeechTranscriber:
//  mic buffers in (any format, converted to the analyzer's), range results out.
//  SpeechTranscriber runs on-device only, so the privacy floor the SFSpeech path
//  had to assert (`requiresOnDeviceRecognition`) holds by construction.
//
//  `start` returns nil whenever the analyzer can't serve this locale ON-DEVICE
//  RIGHT NOW (unsupported device or locale, the language asset not installed):
//  the caller falls back to SFSpeech for this listen, and a missing asset is
//  requested in the background for the next one. A listen never waits on a
//  download.
//
//  Measured against the SFSpeech-era engine (scratch/speechanalyzer-spike,
//  2026-09-26): `.fastResults` brings partials to ~1 s cadence (4 s without),
//  finals land 1-2.5 s after a pause. The fold/endpoint policy that turns those
//  ranges into the consumer's contract is AnalyzerRecognitionPolicy (tested);
//  this file is Speech/AVFoundation glue, verify-by-launch like the rest of the
//  transcriber.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.7 (the calls match the
//  SDK and the file-fed probe; the live mic path is unlaunched). Prior: Unknown.
//

import AVFoundation
import Foundation
import os
import Speech

final class AnalyzerLiveRecognition: @unchecked Sendable {
    private static let log = Logger(subsystem: "app.m1k3", category: "stt")

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let targetFormat: AVAudioFormat
    /// Guards `converter` (rebuilt when the mic format changes) and `stopped`.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var stopped = false
    private var resultsTask: Task<Void, Never>?

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, targetFormat: AVAudioFormat) {
        self.analyzer = analyzer
        self.input = input
        self.targetFormat = targetFormat
    }

    /// Whether SpeechAnalyzer exists on this device at all (sync, for
    /// `isAvailable`); locale and asset are checked per listen in `start`.
    static var deviceSupportsAnalyzer: Bool {
        SpeechTranscriber.isAvailable
    }

    /// Whether a listen in `locale` would run on the analyzer right now: the
    /// device has it, the locale is supported, and its asset is on disk. The
    /// same gates `start` applies, for `isAvailable`'s cache.
    static func servesLocale(_ locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return false }
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == supported.identifier }) {
            return true
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    static func start(
        locale: Locale,
        onResult: @escaping @Sendable (_ text: String, _ isFinal: Bool) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async -> AnalyzerLiveRecognition? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return nil }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        // `installedLocales` is what's on disk; `status(forModules:)` read
        // `.supported` in a test process with en_IE installed and working
        // (2026-09-26), so it alone would send every listen to SFSpeech.
        let onDisk = await SpeechTranscriber.installedLocales.contains { $0.identifier == supported.identifier }
        let status = await AssetInventory.status(forModules: [transcriber])
        guard onDisk || status == .installed else {
            log.notice("speech analyzer asset not installed for \(supported.identifier, privacy: .public) — SFSpeech this listen, requesting it")
            Task.detached {
                try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
            }
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return nil
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            log.error("speech analyzer failed to start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let session = AnalyzerLiveRecognition(analyzer: analyzer, input: input, targetFormat: format)
        session.resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    onResult(String(result.text.characters), result.isFinal)
                }
            } catch is CancellationError {
            } catch {
                onError(error)
            }
        }
        return session
    }

    /// Feed one mic buffer. Called from the tap's render thread; converts to the
    /// analyzer's format (the tap runs at the hardware rate).
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// Idempotent. Ends the input and drops whatever the analyzer hadn't
    /// finalised: a stop is the consumer's decision, same as SFSpeech's cancel.
    func stop() {
        let first = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        input.finish()
        resultsTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        if source == targetFormat { return buffer }
        let converter: AVAudioConverter? = lock.withLock {
            if stopped { return nil }
            if let existing = self.converter, existing.inputFormat == source { return existing }
            self.converter = AVAudioConverter(from: source, to: targetFormat)
            return self.converter
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / source.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
