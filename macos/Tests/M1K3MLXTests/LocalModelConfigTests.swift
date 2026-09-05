//
//  LocalModelConfigTests.swift
//  M1K3MLXTests
//
//  The model_type sniff reads a downloaded repo's config.json so the tool
//  dialect can key on the architecture instead of the repo name. It must be
//  quiet on every failure (no dir, no file, bad JSON, no key) — the name
//  heuristic is the fallback, never a crash on a half-downloaded cache.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.9. Prior: Unknown

import Foundation
@testable import M1K3MLX
import Testing

struct LocalModelConfigTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelConfigTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("reads the top-level model_type from config.json")
    func readsModelType() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"model_type":"qwen3_5","architectures":["Qwen3_5ForConditionalGeneration"],"text_config":{"model_type":"qwen3_5_text"}}"#
        try json.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        #expect(LocalModelConfig.modelType(inDirectory: dir) == "qwen3_5")
    }

    @Test("a local path id (an A/B fused dir) is read directly, tilde expanded")
    func localPathRepoID() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"model_type":"qwen3"}"#.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        #expect(LocalModelConfig.modelType(forRepoID: dir.path) == "qwen3")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if dir.path.hasPrefix(home) {
            let tilde = "~" + dir.path.dropFirst(home.count)
            #expect(LocalModelConfig.modelType(forRepoID: tilde) == "qwen3")
        }
        // A hub id with nothing on disk is quiet nil, never a throw.
        #expect(LocalModelConfig.modelType(forRepoID: "acme/never-downloaded-\(UUID().uuidString)") == nil)
    }

    @Test("nil on a missing directory, a missing file, malformed JSON, or a missing key")
    func quietFailures() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LocalModelConfig.modelType(inDirectory: dir.appendingPathComponent("nope")) == nil)
        #expect(LocalModelConfig.modelType(inDirectory: dir) == nil)
        try "{not json".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        #expect(LocalModelConfig.modelType(inDirectory: dir) == nil)
        try #"{"architectures":["X"]}"#.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        #expect(LocalModelConfig.modelType(inDirectory: dir) == nil)
    }
}
