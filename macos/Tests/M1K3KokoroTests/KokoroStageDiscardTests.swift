//
//  KokoroStageDiscardTests.swift
//  M1K3KokoroTests
//
//  A device that can't run MLX (Apple GPU family 5) must not keep M1K3 Voice's
//  staged weights: the iPad 8th gen staged all 192 MB, then trapped warming
//  them (2026-09-25). The shell discards the stage on such a device; this pins
//  the discard and the staged-check it resets.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-25, Confidence 0.9. Prior: none (new file).
//

import Foundation
@testable import M1K3Kokoro
import Testing

struct KokoroStageDiscardTests {
    private func makeStage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["config.json", "model.safetensors", "voices-v1.0.bin"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    @Test("discarding a full stage leaves nothing staged — and nothing on disk")
    func discardClearsTheStage() throws {
        let directory = try makeStage()
        #expect(KokoroSpeechProvider.isModelStaged(at: directory))

        KokoroSpeechProvider.discardStagedModel(at: directory)

        #expect(!KokoroSpeechProvider.isModelStaged(at: directory))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("discarding a stage that was never there is a quiet no-op")
    func discardMissingStageIsNoOp() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-absent-\(UUID().uuidString)", isDirectory: true)
        KokoroSpeechProvider.discardStagedModel(at: directory)
        #expect(!KokoroSpeechProvider.isModelStaged(at: directory))
    }
}
