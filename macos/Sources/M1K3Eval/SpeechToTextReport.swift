//
//  SpeechToTextReport.swift
//  M1K3Eval
//
//  The speech-to-text eval's pure half (SpeechToTextEvalTests runs the engines):
//  a corpus is `clip-NN.<wav|m4a|caf>` beside `clip-NN.txt` (the line as read,
//  recorded by tools/eval/stt_record.sh); an arm adds up word-weighted error,
//  the real-time factor (processing seconds per audio second: below 1 is faster
//  than speech) and the clips it failed. The report carries no transcripts, so
//  it can be committed; the corpus is a voice and never is.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.85. Prior: Unknown.

import Foundation

public enum SpeechToTextCorpus {
    public struct Clip: Sendable, Equatable {
        public let id: String
        public let audio: URL
        public let reference: String
    }

    static let audioExtensions: Set = ["wav", "m4a", "caf"]

    /// Every audio file with a same-named `.txt` reference, sorted by name.
    public static func clips(in directory: URL) throws -> [Clip] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { audio in
                let id = audio.deletingPathExtension().lastPathComponent
                let text = directory.appendingPathComponent("\(id).txt")
                guard FileManager.default.fileExists(atPath: text.path) else { return nil }
                let reference = try String(contentsOf: text, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Clip(id: id, audio: audio, reference: reference)
            }
    }
}

public struct SpeechToTextArm: Sendable, Encodable, Equatable {
    public let name: String
    public private(set) var errors = 0
    public private(set) var words = 0
    public private(set) var audioSeconds = 0.0
    public private(set) var processingSeconds = 0.0
    public private(set) var failures: [String] = []

    public init(name: String) {
        self.name = name
    }

    public var wordErrorRate: Double {
        words == 0 ? 0 : Double(errors) / Double(words)
    }

    public var realTimeFactor: Double {
        audioSeconds == 0 ? 0 : processingSeconds / audioSeconds
    }

    public mutating func add(_ score: WordErrorRate.Score, audioSeconds: Double, processingSeconds: Double) {
        errors += score.errors
        words += score.words
        self.audioSeconds += audioSeconds
        self.processingSeconds += processingSeconds
    }

    public mutating func fail(clip: String, reason: String) {
        failures.append("\(clip): \(reason)")
    }

    private enum CodingKeys: String, CodingKey {
        case name, errors, words, audioSeconds, processingSeconds, failures, wordErrorRate, realTimeFactor
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(errors, forKey: .errors)
        try container.encode(words, forKey: .words)
        try container.encode(audioSeconds, forKey: .audioSeconds)
        try container.encode(processingSeconds, forKey: .processingSeconds)
        try container.encode(failures, forKey: .failures)
        try container.encode(wordErrorRate, forKey: .wordErrorRate)
        try container.encode(realTimeFactor, forKey: .realTimeFactor)
    }
}

public struct SpeechToTextReport: Sendable, Encodable, Equatable {
    public let date: String
    public let clips: Int
    public let locale: String
    public let arms: [SpeechToTextArm]

    public init(date: String, clips: Int, locale: String, arms: [SpeechToTextArm]) {
        self.date = date
        self.clips = clips
        self.locale = locale
        self.arms = arms
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
