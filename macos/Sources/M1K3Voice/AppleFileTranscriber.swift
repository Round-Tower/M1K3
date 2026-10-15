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
    }

    public static func transcribe(
        _ url: URL, locale: Locale, module: Module, vocabulary: [String] = []
    ) async throws -> String {
        let file = try AVAudioFile(forReading: url)
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
    private static func analyze(_ file: AVAudioFile, modules: [any SpeechModule], context: AnalysisContext) async throws {
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

    private static func join(_ segments: [String]) -> String {
        segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
