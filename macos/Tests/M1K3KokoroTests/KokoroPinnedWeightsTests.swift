//
//  KokoroPinnedWeightsTests.swift
//  M1K3KokoroTests
//
//  Pins the pure decision at the heart of #70: does an on-disk file at
//  `name` match the digest pinned for `mlx-community/Kokoro-82M-bf16`, or
//  does `prepare(progress:)` need to discard it and re-fetch from the pinned
//  revision? Kept dependency-free (no filesystem) so the trust-vs-re-fetch
//  decision is provable in isolation from `KokoroSpeechProvider`'s IO.
//
//  Signed: Kev + claude-sonnet-5, 2026-09-01, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3Kokoro
import Testing

struct KokoroPinnedWeightsTests {
    @Test("the pinned revision is a full 40-char commit SHA, never a branch name")
    func revisionIsAFullCommitSHA() {
        // Mirrors WeightIntegrity.Pin's own contract: a branch name (like
        // "main") is exactly the moving target this pin exists to remove.
        #expect(KokoroPinnedWeights.revision.count == 40)
        #expect(KokoroPinnedWeights.revision.allSatisfy { $0.isHexDigit })
    }

    @Test("bytes matching the pinned size and digest are trusted")
    func matchingBytesAreTrusted() throws {
        #expect(try KokoroPinnedWeights.matches(size: 2351, sha256: #require(KokoroPinnedWeights.files["config.json"]?.sha256), file: "config.json"))
        #expect(try KokoroPinnedWeights.matches(
            size: 327_115_152,
            sha256: #require(KokoroPinnedWeights.files["model.safetensors"]?.sha256),
            file: "model.safetensors"
        ))
    }

    @Test("a digest disagreement is NOT trusted, even at the right size")
    func wrongDigestIsNotTrusted() {
        #expect(!KokoroPinnedWeights.matches(size: 2351, sha256: "0000000000000000000000000000000000000000000000000000000000000", file: "config.json"))
    }

    @Test("a size disagreement is NOT trusted, even with the right digest string reused")
    func wrongSizeIsNotTrusted() throws {
        let pinnedDigest = try #require(KokoroPinnedWeights.files["config.json"]?.sha256)
        #expect(!KokoroPinnedWeights.matches(size: 1, sha256: pinnedDigest, file: "config.json"))
    }

    @Test("a filename this manifest doesn't pin passes through — not this pin's concern")
    func unrecognisedFileIsUntouched() {
        // voices-v1.0.bin comes from a different host entirely (a GitHub
        // release, not HuggingFace) and is deliberately out of this pin's
        // scope — see the KokoroPinnedWeights header.
        #expect(KokoroPinnedWeights.matches(size: 1, sha256: "anything", file: "voices-v1.0.bin"))
    }

    @Test("the manifest pins exactly the two HuggingFace-sourced files, not the GitHub-sourced voices")
    func manifestScopeIsExactlyTheTwoHFFiles() {
        #expect(Set(KokoroPinnedWeights.files.keys) == ["config.json", "model.safetensors"])
    }

    // MARK: - sha256Digest (the IO half; no network, no Metal — plain file reads)

    @Test("sha256Digest matches a known digest for known bytes")
    func sha256DigestMatchesKnownBytes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-pin-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("sample.bin")
        try Data("hello kokoro".utf8).write(to: file)

        // Independently known sha256("hello kokoro") — `printf 'hello kokoro' | shasum -a 256`.
        let expected = "9ce4ec439294ed1c90d14038a92b29eacde1d61401e7670af21192c124ae5e9a"
        #expect(KokoroPinnedWeights.sha256Digest(of: file) != nil)
        #expect(KokoroPinnedWeights.sha256Digest(of: file) == expected)
    }

    @Test("sha256Digest returns nil for a missing file")
    func sha256DigestReturnsNilForMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-pin-fixture-missing-\(UUID().uuidString).bin")
        #expect(KokoroPinnedWeights.sha256Digest(of: missing) == nil)
    }
}
