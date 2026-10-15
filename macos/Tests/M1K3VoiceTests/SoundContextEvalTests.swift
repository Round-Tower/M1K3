//
//  SoundContextEvalTests.swift
//  M1K3VoiceTests
//
//  The SoundContext eval: every file of the corpus (tools/eval/sound_corpus.sh)
//  through SoundContextListener.analyze(file:), scored against its folder:
//  speech/, speech-over-music/ and other/ should be taken; music/ should read
//  as music without a speaker. Gated, local only:
//
//    M1K3_SOUND_EVAL=1 [M1K3_SOUND_CORPUS=<dir>] [M1K3_SOUND_OUT=<json>] \
//      swift test --filter SoundContextEvalTests
//
//  The report carries counts and the context lines, never audio. It asserts
//  nothing about the rates: no threshold is set from one corpus.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.75. Prior: Unknown.

import AVFoundation
import Foundation
@testable import M1K3Voice
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_SOUND_EVAL"] == "1"))
struct SoundContextEvalTests {
    struct Folder: Encodable {
        let name: String
        let expected: String
        var files = 0
        var correct = 0
        var misses: [String] = []
        var lines: [String: Int] = [:]
    }

    @Test("every file is classified and the report is written")
    func runEval() throws {
        let env = ProcessInfo.processInfo.environment
        let corpus = URL(fileURLWithPath: env["M1K3_SOUND_CORPUS"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/m1k3-sound-corpus").path)
        var folders: [Folder] = []
        for (name, expected) in [
            ("speech", SoundContext.Verdict.take), ("speech-over-music", .take),
            ("other", .take), ("music", .musicWithoutSpeech),
        ] {
            var folder = Folder(name: name, expected: "\(expected)")
            let files = try FileManager.default
                .contentsOfDirectory(at: corpus.appendingPathComponent(name), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
            for file in files {
                let heard = try SoundContextListener.analyze(file: file)
                folder.files += 1
                if heard.verdict == expected {
                    folder.correct += 1
                } else {
                    folder.misses.append(file.lastPathComponent)
                }
                folder.lines[heard.contextLine ?? "(none)", default: 0] += 1
            }
            print("SOUND \(name): \(folder.correct)/\(folder.files) as \(expected)")
            folders.append(folder)
        }
        let streamMismatches = try streamPathMismatches(corpus: corpus)
        print("SOUND stream path: \(streamMismatches.count) verdicts differ from the file path \(streamMismatches)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let out = env["M1K3_SOUND_OUT"].map(URL.init(fileURLWithPath:)) ?? corpus.appendingPathComponent("report.json")
        try encoder.encode(folders).write(to: out)
        print("SOUND report: \(out.path)")
        #expect(folders.allSatisfy { $0.files > 0 })
    }

    /// The live path: speech files through `append` in 100 ms buffers, as a mic tap feeds
    /// them; each verdict should match the file path's.
    private func streamPathMismatches(corpus: URL) throws -> [String] {
        var mismatches: [String] = []
        for name in ["speech", "speech-over-music"] {
            let files = try FileManager.default
                .contentsOfDirectory(at: corpus.appendingPathComponent(name), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
            for file in files {
                let audio = try AVAudioFile(forReading: file)
                let format = audio.processingFormat
                let listener = try #require(SoundContextListener(format: format, maxPending: .max))
                let chunk = AVAudioFrameCount(format.sampleRate / 10)
                while audio.framePosition < audio.length {
                    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk))
                    try audio.read(into: buffer, frameCount: chunk)
                    listener.append(buffer)
                }
                listener.finish()
                if try listener.context.verdict != SoundContextListener.analyze(file: file).verdict {
                    mismatches.append(file.lastPathComponent)
                }
            }
        }
        return mismatches
    }
}
