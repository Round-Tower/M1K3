//
//  KokoroSpeedTests.swift
//  M1K3KokoroTests
//
//  #576 §1: Kokoro now speaks at the utterance's speed (a mood's pace), held to
//  the range where its duration predictor still sounds natural. Synthesis itself
//  is MLX and verify-by-launch; the clamp is pure.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.9 (pure). Prior: none (new file).
//

import Foundation
import M1K3Kokoro
import Testing

struct KokoroSpeedTests {
    @Test("Kokoro follows the utterance's speed inside 0.8...1.25")
    func clamped() {
        #expect(KokoroSpeechProvider.kokoroSpeed(1) == 1)
        #expect(abs(KokoroSpeechProvider.kokoroSpeed(1.12) - 1.12) < 0.0001)
        #expect(abs(KokoroSpeechProvider.kokoroSpeed(0.85) - 0.85) < 0.0001)
        #expect(KokoroSpeechProvider.kokoroSpeed(2) == 1.25, "the fastest Apple rate would garble Kokoro")
        #expect(KokoroSpeechProvider.kokoroSpeed(0) == 0.8)
        #expect(KokoroSpeechProvider.kokoroSpeed(.nan) == 1)
    }

    @Test("synthesis runs at the utterance's speed, so Kokoro follows a mood's pace")
    func synthesisUsesTheUtterancesSpeed() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/M1K3Kokoro/KokoroSpeechProvider.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("speed: Self.kokoroSpeed(utterance.speedMultiplier)"))
    }
}
