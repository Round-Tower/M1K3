//
//  TTSRoundTripStage.swift
//  M1K3App
//
//  #838 slice 1: the Kokoro → Whisper round trip, inside the built app because Kokoro
//  is MLX (the metallib wall). Kokoro speaks every item of `TTSRoundTrip.corpus`, the
//  clip is written as `clip-<id>.wav` beside the `clip-<id>.txt` it should sound like
//  (so the STT eval's SpeechToTextCorpus can run every other engine on it too),
//  WhisperKit transcribes it, and each class is scored with WordErrorRate against the
//  written OR the spoken reading. The G2P fallback that spoke each word is counted per
//  class: the letter-to-sound share is the measured hard-word rate.
//
//      M1K3_SELFTEST=1 M1K3_SELFTEST_OUT=- M1K3_SELFTEST_TTSRT=1 \
//      M1K3_SELFTEST_TTSRT_VOICE=bm_daniel        (optional; the app's voice by default) \
//      M1K3_SELFTEST_TTSRT_WHISPER=small.en       (optional; the downloaded variant by default) \
//      M1K3_SELFTEST_TTSRT_KINDS=numbers,passage  (optional; every class by default) \
//      M1K3.app/Contents/MacOS/M1K3 | grep '^TTSRT'
//
//  M1K3_SELFTEST_TTSRT_EMIT_AUDIO=1 also streams each clip as `TTSRTWAV <id> <base64 wav>`
//  (the container is closed to the host), for listening by ear off the Mac.
//
//  Rows: `TTSRT <id> <errors>/<words> <heard>`; the last line is `TTSRTREPORT <json>`
//  (numbers only, committable). The clips and report stay in the container's tmp under
//  `tts-roundtrip/`. Quit the live app first: two MLX processes crawl.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.7 (compiles in the app shell;
//  the first launch is the run itself). Prior: none (new file; ReadEvalStage's shape).
//  Format: MurphySig v0.4 (https://murphysig.dev/spec)
//

import Foundation
import M1K3Eval
import M1K3Kokoro
import M1K3WhisperKit

enum TTSRoundTripStage {
    static var isRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_TTSRT") == "1"
    }

    static func run(emit: @escaping (String) -> Void) async {
        let voice = SelfTestEnv.value("M1K3_SELFTEST_TTSRT_VOICE") ?? "bm_daniel"
        guard TTSRoundTrip.isVoiceID(voice) else {
            emit("✗ ttsrt: not a Kokoro voice id")
            return
        }
        let kinds = SelfTestEnv.value("M1K3_SELFTEST_TTSRT_KINDS").map {
            Set($0.split(separator: ",").compactMap { TTSRoundTrip.Kind(rawValue: String($0)) })
        } ?? Set(TTSRoundTrip.Kind.allCases)
        let items = TTSRoundTrip.corpus.filter { kinds.contains($0.kind) }
        let emitAudio = SelfTestEnv.value("M1K3_SELFTEST_TTSRT_EMIT_AUDIO") == "1"
        let downloadBase: URL
        do {
            downloadBase = try await MainActor.run { try AppEnvironment.storeURL() }.deletingLastPathComponent()
        } catch {
            emit("✗ ttsrt: no store folder (\(error))")
            return
        }
        let whisper = SelfTestEnv.value("M1K3_SELFTEST_TTSRT_WHISPER")
            ?? [WhisperModelVariant.small, .base, .tiny].first {
                WhisperKitProvider.isModelDownloaded(model: $0.modelID, downloadBase: downloadBase)
            }?.modelID
            ?? WhisperModelVariant.small.modelID
        guard WhisperModelVariant.allCases.contains(where: { $0.modelID == whisper }) else {
            emit("✗ ttsrt: not a WhisperKit variant (\(WhisperModelVariant.allCases.map(\.modelID)))")
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tts-roundtrip", isDirectory: true)
        emit("• ttsrt: \(items.count) items, voice \(voice), whisper \(whisper), clips in \(folder.lastPathComponent)/")

        let g2p: KokoroG2P
        let synthesizer = KokoroSynthesizer(modelDirectory: KokoroSpeechProvider.defaultModelDirectory(), voice: voice)
        let transcriber = WhisperKitBatchTranscriber(model: whisper, downloadBase: downloadBase)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            g2p = try KokoroG2P.bundled()
            try await synthesizer.preload()
            try await transcriber.prepareModel(progress: { _ in })
        } catch {
            emit("✗ ttsrt: setup failed (\(error))")
            return
        }

        var arms: [TTSRoundTrip.Kind: SpeechToTextArm] = [:]
        var fallbacks: [String: [String: Int]] = [:]
        var keys: [String: TTSRoundTripReport.KeyTally] = [:]
        let clock = ContinuousClock()
        for item in items {
            for (source, count) in g2p.annotatedTokens(item.text).sourceCounts {
                fallbacks[item.kind.rawValue, default: [:]][source.rawValue, default: 0] += count
            }
            var arm = arms[item.kind] ?? SpeechToTextArm(name: item.kind.rawValue)
            do {
                let samples = try await synthesizer.synthesize(text: item.text)
                let audio = folder.appendingPathComponent("\(item.clipName).wav")
                try PCMWave.data(samples: samples, sampleRate: Int(KokoroSynthesizer.sampleRate)).write(to: audio)
                try item.spoken.write(to: folder.appendingPathComponent("\(item.clipName).txt"),
                                      atomically: true, encoding: .utf8)
                // The container is closed to the host on macOS 27: M1K3_SELFTEST_TTSRT_EMIT_AUDIO=1
                // streams each clip on stdout (one base64 line) for listening off the Mac.
                if emitAudio {
                    let wav = try Data(contentsOf: audio)
                    emit("TTSRTWAV\t\(item.id)\t\(wav.base64EncodedString())")
                }
                let start = clock.now
                let heard = try await transcriber.transcribe(fileURL: audio).map(\.text).joined(separator: " ")
                let elapsed = clock.now - start
                let score = TTSRoundTrip.score(item, heard: heard)
                arm.add(score, audioSeconds: Double(samples.count) / KokoroSynthesizer.sampleRate,
                        processingSeconds: Double(elapsed.components.seconds)
                            + Double(elapsed.components.attoseconds) / 1e18)
                let heardKeys = TTSRoundTrip.keysHeard(item, heard: heard)
                if !item.keys.isEmpty {
                    keys[item.kind.rawValue, default: .init()].heard += heardKeys
                    keys[item.kind.rawValue, default: .init()].total += item.keys.count
                }
                emit("TTSRT\t\(item.id)\t\(score.errors)/\(score.words)\tkeys \(heardKeys)/\(item.keys.count)\t\(heard)")
            } catch {
                // The report is committed: a reason is the error's type, never a path.
                arm.fail(clip: item.id, reason: String(describing: type(of: error)))
                arm.add(TTSRoundTrip.failedScore(item), audioSeconds: 0, processingSeconds: 0)
                if !item.keys.isEmpty { keys[item.kind.rawValue, default: .init()].total += item.keys.count }
                emit("TTSRT\t\(item.id)\tfailed\t\(type(of: error))")
            }
            arms[item.kind] = arm
        }

        let ordered = TTSRoundTrip.Kind.allCases.compactMap { arms[$0] }
        let report = TTSRoundTripReport(
            speech: SpeechToTextReport(date: Self.today(), clips: items.count, locale: "en_GB", arms: ordered),
            voice: voice, transcriber: "WhisperKit \(whisper)", fallbacks: fallbacks, keys: keys
        )
        for arm in ordered {
            let tally = keys[arm.name].map { String(format: ", keys heard %d/%d", $0.heard, $0.total) } ?? ""
            emit(String(format: "• ttsrt %@: %d/%d words wrong (%.1f%%)%@",
                        arm.name, arm.errors, arm.words, arm.wordErrorRate * 100, tally))
        }
        do {
            let data = try report.encoded()
            try data.write(to: folder.appendingPathComponent("report.json"))
            let line = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "")
            emit("TTSRTREPORT\t\(line)")
        } catch {
            emit("✗ ttsrt: report failed (\(error))")
        }
    }

    private static func today() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date())
    }
}
