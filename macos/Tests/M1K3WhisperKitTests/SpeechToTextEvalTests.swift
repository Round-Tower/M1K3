//
//  SpeechToTextEvalTests.swift
//  M1K3WhisperKitTests
//
//  The speech-to-text eval: every clip of a recorded corpus (tools/eval/stt_record.sh)
//  through five arms, scored by WordErrorRate. Gated, local only:
//
//    M1K3_STT_EVAL=1 [M1K3_STT_CORPUS=<dir>] [M1K3_STT_VOCAB=<file>] [M1K3_STT_OUT=<json>] \
//      [M1K3_STT_ARMS=<comma-separated name fragments>] swift test --filter SpeechToTextEvalTests
//
//  The "polish" arm (#852) is the shipped polish pass: the shipped-fast text stands in for the
//  live final, AppleBufferTranscriber runs the accurate pass over the clip's samples (padded with
//  trailing silence exactly as a live turn is), and VoicePolisher's own policy and 1 s budget
//  decide which text stands. Its per-clip pass latency is printed beside the WER.
//  M1K3_STT_ARMS=fast,polish skips the rest (and Whisper's download).
//
//  Arms: the analyzer as voice mode ships it (SpeechTranscriber, `.fastResults`), the
//  analyzer without `.fastResults`, the shipped analyzer with a vocabulary (contextual
//  strings: M1K3_STT_VOCAB, one per line; without it, the corpus's own capitalised names,
//  an oracle upper bound the report labels as such), DictationTranscriber, and WhisperKit
//  small.en (the dictation default) downloaded into the eval's own cache, never the app's.
//  The corpus defaults to the newest folder in ~/.cache/m1k3-stt-corpus. The committed
//  report carries numbers only; the transcripts go beside the corpus.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.65 (engine glue; the scoring
//  and pairing it relies on are pinned in M1K3EvalTests). Prior: Unknown.
//  Review: claude-opus-5-5, 2026-10-15: the arms moved into engines(...) (lint: body length);
//  the summary pads names itself, since %-34@ doesn't pad an NSString. A failure reason
//  is the error's case or type, never its description (a path can carry a username).
//  Review: claude-opus-5-5, 2026-11-16 (#852): the "polish" arm, per-arm latency median/p90, and
//  M1K3_STT_ARMS to run a subset. Confidence 0.75 (numbers recorded in docs/evals/2026-11-16-polish-pass).

import AVFoundation
import Foundation
import M1K3Eval
import M1K3Voice
import M1K3WhisperKit
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_STT_EVAL"] == "1"), .serialized)
struct SpeechToTextEvalTests {
    private let env = ProcessInfo.processInfo.environment
    private let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")

    @Test("every arm transcribes the corpus and the report is written")
    func runEval() async throws {
        let corpus = try corpusDirectory()
        let clips = try SpeechToTextCorpus.clips(in: corpus)
        try #require(!clips.isEmpty, "no clips in \(corpus.path): record with tools/eval/stt_record.sh")
        let locale = Locale(identifier: env["M1K3_STT_LOCALE"] ?? "en_IE")
        let (vocabulary, oracle) = try vocabularyList(clips: clips)

        let arms = try await engines(locale: locale, vocabulary: vocabulary, oracle: oracle)

        var results: [SpeechToTextArm] = []
        var transcripts: [String] = []
        for (name, engine) in arms {
            var arm = SpeechToTextArm(name: name)
            var latencies: [Double] = []
            for clip in clips {
                let seconds = try duration(of: clip.audio)
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    let heard = try await engine(clip.audio)
                    let elapsed = clock.now - start
                    let score = WordErrorRate.score(reference: clip.reference, hypothesis: heard)
                    let processing = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    arm.add(score, audioSeconds: seconds, processingSeconds: processing)
                    latencies.append(processing)
                    transcripts.append(
                        "[\(name)] \(clip.id) \(score.errors)/\(score.words)\n  ref: \(clip.reference)\n  hyp: \(heard)"
                    )
                } catch {
                    // The report is committed: a reason names the failure, never a path.
                    let reason = (error as? AppleFileTranscriber.Failure).map { String(describing: $0) }
                        ?? String(describing: type(of: error))
                    arm.fail(clip: clip.id, reason: reason)
                }
            }
            results.append(arm)
            Self.printLatency(name, latencies)
        }
        polishLog.printSummary()

        let report = SpeechToTextReport(
            date: Self.today(), clips: clips.count, locale: locale.identifier, arms: results
        )
        let out = env["M1K3_STT_OUT"].map(URL.init(fileURLWithPath:))
            ?? corpus.appendingPathComponent("report.json")
        try report.encoded().write(to: out)
        try transcripts.joined(separator: "\n").write(
            to: corpus.appendingPathComponent("transcripts.txt"), atomically: true, encoding: .utf8
        )
        for arm in results {
            let name = arm.name.padding(toLength: 34, withPad: " ", startingAt: 0)
            print(String(format: "STT %@ WER %5.1f%%  RTF %.3f  failed %d",
                         name, arm.wordErrorRate * 100, arm.realTimeFactor, arm.failures.count))
        }
        print("STT report: \(out.path)")
        #expect(results.allSatisfy { $0.words > 0 || !$0.failures.isEmpty })
    }

    private typealias Engine = @Sendable (URL) async throws -> String

    /// What the polish arm's pass did on each clip (seconds, and why a live text was kept).
    private let polishLog = PolishLog()

    private static func printLatency(_ name: String, _ seconds: [Double]) {
        guard !seconds.isEmpty else { return }
        let sorted = seconds.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
        print(String(format: "STT latency %@ median %.3f s  p90 %.3f s  (n=%d)",
                     name.padding(toLength: 34, withPad: " ", startingAt: 0), median, p90, sorted.count))
    }

    /// The arms, in report order. Whisper downloads into the eval's own cache first.
    private func engines(locale: Locale, vocabulary: [String], oracle: Bool) async throws -> [(String, Engine)] {
        let whisper = WhisperKitBatchTranscriber(
            model: WhisperModelVariant.defaultVariant.modelID,
            downloadBase: cache.appendingPathComponent("m1k3-stt-eval/whisper")
        )
        let wanted = env["M1K3_STT_ARMS"]?.lowercased().split(separator: ",").map(String.init)
        func selected(_ name: String) -> Bool {
            wanted?.contains { name.lowercased().contains($0) } ?? true
        }
        if selected("whisper") { try await whisper.prepareModel { _ in } }
        func apple(_ module: AppleFileTranscriber.Module, vocabulary: [String] = []) -> Engine {
            { try await AppleFileTranscriber.transcribe($0, locale: locale, module: module, vocabulary: vocabulary) }
        }
        let vocabArm = oracle ? "analyzer+vocab (oracle names)" : "analyzer+vocab"
        let polishLog = polishLog
        let polisher = VoicePolisher(enabled: true) { audio in
            try await AppleBufferTranscriber.transcribe(audio, locale: locale)
        }
        let all: [(String, Engine)] = [
            ("analyzer (shipped, fast)", apple(.speech(fast: true))),
            ("polish (fast live + accurate pass)", { url in
                let live = try await AppleFileTranscriber.transcribe(url, locale: locale, module: .speech(fast: true))
                let outcome = try await polisher.run(live: live, audio: Self.samples(of: url))
                polishLog.record(outcome)
                return outcome.text
            }),
            ("analyzer (accurate)", apple(.speech(fast: false))),
            (vocabArm, apple(.speech(fast: true), vocabulary: vocabulary)),
            ("dictation", apple(.dictation)),
            ("dictation+vocab", apple(.dictation, vocabulary: vocabulary)),
            ("whisper \(WhisperModelVariant.defaultVariant.rawValue)", { url in
                try await whisper.transcribe(fileURL: url).map(\.text).joined(separator: " ")
            }),
        ]
        return all.filter { selected($0.0) }
    }

    /// The clip as the mic tap would have delivered it: mono float samples at the file's rate.
    private static func samples(of url: URL) throws -> UtteranceAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AppleBufferTranscriber.Failure.unusableAudio
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw AppleBufferTranscriber.Failure.unusableAudio }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return UtteranceAudio(samples: samples, sampleRate: format.sampleRate, truncated: false)
    }

    private func corpusDirectory() throws -> URL {
        if let path = env["M1K3_STT_CORPUS"] { return URL(fileURLWithPath: path) }
        let root = cache.appendingPathComponent("m1k3-stt-corpus")
        let folders = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try #require(folders.last, "no corpus under \(root.path)")
    }

    /// The vocabulary arm's list, and whether it is the oracle stand-in (the corpus's own names).
    private func vocabularyList(clips: [SpeechToTextCorpus.Clip]) throws -> ([String], Bool) {
        if let path = env["M1K3_STT_VOCAB"] {
            let lines = try String(contentsOfFile: path, encoding: .utf8)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (lines, false)
        }
        // Runs of capitalised words that don't open a sentence, as phrases ("Dún Laoghaire"):
        // the names a memory graph would hold. Contextual strings bias by phrase.
        var names: Set<String> = []
        for clip in clips {
            let words = clip.reference.split(separator: " ").map { String($0) }
            var run: [String] = []
            func close() {
                if !run.isEmpty { names.insert(run.joined(separator: " ")) }
                run = []
            }
            for (index, raw) in words.enumerated() {
                let word = raw.trimmingCharacters(in: .punctuationCharacters)
                if index > 0, word.first?.isUppercase == true, word != "I" { run.append(word) } else { close() }
                if raw.last.map({ ",.?!;:".contains($0) }) == true { close() }
            }
            close()
        }
        return (names.sorted(), true)
    }

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// The polish arm's outcomes across clips, summarised after the run.
private final class PolishLog: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [VoicePolisher.Outcome] = []

    func record(_ outcome: VoicePolisher.Outcome) {
        lock.withLock { outcomes.append(outcome) }
    }

    func printSummary() {
        let all = lock.withLock { outcomes }
        guard !all.isEmpty else { return }
        let changed = all.filter(\.changed).count
        let kept = Dictionary(grouping: all.compactMap(\.reason), by: { $0.rawValue }).mapValues(\.count)
        let times = all.map(\.seconds).sorted()
        let median = times[times.count / 2]
        let p90 = times[min(times.count - 1, Int((Double(times.count) * 0.9).rounded(.up)) - 1)]
        print(String(format: "STT polish pass only: median %.3f s  p90 %.3f s  max %.3f s  changed %d/%d  kept %@",
                     median, p90, times.last ?? 0, changed, all.count, kept.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")))
    }
}
