//
//  WeightIntegrityScanTests.swift
//  M1K3MLXTests
//
//  Real filesystem tests for the enforcement layer.
//
//  These exist because review correctly called out that the IO half had no
//  direct coverage, and that the reason given for it was wrong. The header of
//  WeightIntegrityScan claimed the metallib wall as the excuse — but that file
//  imports CryptoKit, Foundation and os, and nothing else. There is no Metal
//  here, so nothing stops a temp directory and a real SHA256 from running
//  under `swift test`. The excuse was inherited reflexively from the rest of
//  M1K3MLX rather than checked.
//
//  What actually cannot be tested here is the refusal reaching a real model
//  load, which needs the app bundle. Everything below — hashing, the receipt
//  round-trip, the throw — is ordinary file IO.
//

import Foundation
@testable import M1K3MLX
import Testing

struct WeightIntegrityScanTests {
    /// A temp directory that cleans itself up, standing in for a model cache.
    private struct Sandbox: ~Copyable {
        let url: URL

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("weight-integrity-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func write(_ contents: String, to name: String) throws {
            try Data(contents.utf8).write(to: url.appendingPathComponent(name))
        }

        /// Mimics HubApi's own provenance record: `<dir>/.cache/huggingface/
        /// download/<file>.metadata`, whose first line is the commit the file
        /// was fetched at.
        func writeDownloadMetadata(commit: String, for name: String) throws {
            let dir = url.appendingPathComponent(".cache/huggingface/download")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("\(commit)\netag\n0\n".utf8)
                .write(to: dir.appendingPathComponent("\(name).metadata"))
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private static func sha256Hex(_ text: String) -> String {
        // Mirrors the production hash so fixtures stay honest: the pin must
        // hold the digest of the bytes actually written, not a made-up one.
        var hasher = SHA256Fixture()
        hasher.update(Data(text.utf8))
        return hasher.hexDigest()
    }

    private static func pin(revision: String = "abc", contents: [String: String]) -> WeightIntegrity.Pin {
        var files: [String: WeightIntegrity.PinnedFile] = [:]
        for (name, body) in contents {
            files[name] = .init(size: Data(body.utf8).count, sha256: sha256Hex(body))
        }
        return .init(revision: revision, files: files)
    }

    @Test("matching bytes verify, and leave a receipt behind")
    func verifiesAndWritesReceipt() throws {
        let sandbox = try Sandbox()
        try sandbox.write("weights", to: "model.safetensors")
        let pin = Self.pin(contents: ["model.safetensors": "weights"])

        try WeightIntegrityScan.enforce(directory: sandbox.url, pin: pin, repoID: "org/repo")

        #expect(WeightIntegrityScan.receiptExists(forModelAt: sandbox.url))
    }

    @Test("a file whose bytes disagree with the pin throws, and is NOT deleted")
    func tamperThrowsAndPreservesEvidence() throws {
        let sandbox = try Sandbox()
        try sandbox.write("poisoned", to: "model.safetensors")
        // Pin the digest of different content of the SAME length, so this is a
        // digest disagreement rather than a size one.
        let pin = Self.pin(contents: ["model.safetensors": "weights!"])

        #expect(throws: WeightTamperError.self) {
            try WeightIntegrityScan.enforce(directory: sandbox.url, pin: pin, repoID: "org/repo")
        }

        // Evidence, not garbage: refusing must not destroy what it refused.
        #expect(FileManager.default.fileExists(atPath: sandbox.url.appendingPathComponent("model.safetensors").path))
        #expect(!WeightIntegrityScan.receiptExists(forModelAt: sandbox.url))
    }

    @Test("a download still in flight is incomplete, not an alarm, and writes no receipt")
    func inFlightDownloadIsSilent() throws {
        let sandbox = try Sandbox()
        let pin = Self.pin(contents: ["model.safetensors": "weights", "config.json": "{}"])

        // Nothing on disk yet — the ordinary first-run state.
        try WeightIntegrityScan.enforce(directory: sandbox.url, pin: pin, repoID: "org/repo")

        #expect(!WeightIntegrityScan.receiptExists(forModelAt: sandbox.url))
    }

    /// The receipt exists to avoid re-hashing gigabytes on every launch, so
    /// "it was actually reused" is the behaviour worth pinning — not merely
    /// that a file appeared.
    @Test("a second verification reuses the receipt instead of rehashing")
    func receiptIsReused() throws {
        let sandbox = try Sandbox()
        try sandbox.write("weights", to: "model.safetensors")
        let pin = Self.pin(contents: ["model.safetensors": "weights"])

        try WeightIntegrityScan.enforce(directory: sandbox.url, pin: pin, repoID: "org/repo")

        // Corrupt the bytes WITHOUT changing size or mtime. A rehash would now
        // fail; reuse of the receipt means it passes. That is exactly the trade
        // the receipt makes, and it is only sound because a genuine re-download
        // bumps mtime (covered by the next test).
        //
        // Both writes are stamped to the SAME fixed instant rather than reading
        // and restoring the original: setAttributes does not round-trip a Date
        // with full fidelity, so restoring "the old mtime" produced a value
        // that differed slightly and defeated the very reuse under test.
        let target = sandbox.url.appendingPathComponent("model.safetensors")
        let frozen = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try FileManager.default.setAttributes([.modificationDate: frozen], ofItemAtPath: target.path)
        try WeightIntegrityScan.enforce(directory: sandbox.url, pin: pin, repoID: "org/repo")

        try Data("WEIGHTS".utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: frozen], ofItemAtPath: target.path)

        try WeightIntegrityScan.enforce(directory: sandbox.url, pin: pin, repoID: "org/repo")
    }

    /// The security-review finding that mattered most, end to end: a re-fetch
    /// at the same size must not inherit the old attestation.
    @Test("a re-downloaded file at the same size is rehashed, and refused if wrong")
    func refetchIsRehashed() throws {
        let sandbox = try Sandbox()
        try sandbox.write("weights", to: "model.safetensors")
        let pin = Self.pin(contents: ["model.safetensors": "weights"])

        try WeightIntegrityScan.enforce(directory: sandbox.url, pin: pin, repoID: "org/repo")

        // Same length, different bytes, and a fresh mtime — a hostile re-serve.
        let target = sandbox.url.appendingPathComponent("model.safetensors")
        try Data("WEIGHTS".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: target.path
        )

        #expect(throws: WeightTamperError.self) {
            try WeightIntegrityScan.enforce(directory: sandbox.url, pin: pin, repoID: "org/repo")
        }
    }

    @Test("a receipt planted in the model directory cannot vouch for anything")
    func plantedReceiptIsIgnored() throws {
        let sandbox = try Sandbox()
        try sandbox.write("poisoned", to: "model.safetensors")
        let pin = Self.pin(contents: ["model.safetensors": "weights!"])

        // The download globs include "*.json", so a hostile repo can ship a
        // file named like a receipt and have it land right here. Receipts
        // therefore live outside the directory the downloader writes to, and
        // anything planted inside it is inert.
        let forged = """
        {"revision":"abc","files":{"model.safetensors":{"size":8,"modified":0}}}
        """
        try sandbox.write(forged, to: ".m1k3-weight-receipt.json")
        try sandbox.write(forged, to: "m1k3-weight-receipt.json")

        #expect(throws: WeightTamperError.self) {
            try WeightIntegrityScan.enforce(directory: sandbox.url, pin: pin, repoID: "org/repo")
        }
    }

    /// A false accusation is its own kind of failure.
    ///
    /// After a re-pin (a brain promotion), a user still holding the PREVIOUS
    /// release's weights has bytes that legitimately disagree with the new
    /// manifest. Online that is invisible — the new revision downloads first.
    /// But `download`'s offline and auth-required exits hand back the stale
    /// local copy and then verify it, so an honest user launching without a
    /// network got `WeightTamperError`: a supply-chain accusation, on a path
    /// deliberately built never to self-heal.
    ///
    /// HubApi records the commit each file was fetched at, which distinguishes
    /// "these are last release's weights" from "these bytes are wrong".
    @Test("weights from a previous pinned revision read as stale, never as tampering")
    func staleRevisionIsNotTampering() throws {
        let sandbox = try Sandbox()
        try sandbox.write("old weights", to: "model.safetensors")
        try sandbox.writeDownloadMetadata(commit: "0000000000000000000000000000000000000000", for: "model.safetensors")

        // The pin expects different bytes at a different commit — exactly the
        // post-promotion state.
        let pin = Self.pin(
            revision: "1111111111111111111111111111111111111111",
            contents: ["model.safetensors": "new weights"]
        )

        #expect(throws: WeightsStaleError.self) {
            try WeightIntegrityScan.enforce(directory: sandbox.url, pin: pin, repoID: "org/repo")
        }
    }

    @Test("bytes that disagree at the PINNED commit are still tampering")
    func wrongBytesAtPinnedCommitStillTamper() throws {
        let sandbox = try Sandbox()
        try sandbox.write("poisoned!", to: "model.safetensors")
        try sandbox.writeDownloadMetadata(commit: "1111111111111111111111111111111111111111", for: "model.safetensors")

        let pin = Self.pin(
            revision: "1111111111111111111111111111111111111111",
            contents: ["model.safetensors": "weights!!"]
        )

        #expect(throws: WeightTamperError.self) {
            try WeightIntegrityScan.enforce(directory: sandbox.url, pin: pin, repoID: "org/repo")
        }
    }

    @Test("an unpinned repo is left alone entirely")
    func unpinnedIsUntouched() throws {
        let sandbox = try Sandbox()
        try sandbox.write("anything", to: "model.safetensors")

        try WeightIntegrityScan.enforce(directory: sandbox.url, pin: nil, repoID: "org/unpinned")

        #expect(!WeightIntegrityScan.receiptExists(forModelAt: sandbox.url))
    }

    // MARK: - isFullyPresentAndVerified (#72 item 1: the useLatest pre-network check)

    /// The decision `HubApiDownloader.download` needs before it ever touches
    /// the network (#72 item 1): every pinned file present AND byte-verified.
    /// Shares `enforce`'s own decision core rather than a second verdict path
    /// — the same idiom `WeightImport.verifiedAlready` already used, now
    /// factored out here so both callers reuse ONE implementation.
    @Test("a fully downloaded, byte-matching directory is fully present and verified")
    func fullyVerifiedDirectoryIsRecognised() throws {
        let sandbox = try Sandbox()
        try sandbox.write("weights", to: "model.safetensors")
        try sandbox.write("{}", to: "config.json")
        let pin = Self.pin(contents: ["model.safetensors": "weights", "config.json": "{}"])

        #expect(WeightIntegrityScan.isFullyPresentAndVerified(directory: sandbox.url, pin: pin, repoID: "org/repo"))
    }

    @Test("a partial download (missing pinned files) is NOT fully present and verified")
    func partialDownloadIsNotFullyVerified() throws {
        let sandbox = try Sandbox()
        try sandbox.write("weights", to: "model.safetensors")
        // config.json never arrived — an ordinary in-flight download.
        let pin = Self.pin(contents: ["model.safetensors": "weights", "config.json": "{}"])

        #expect(!WeightIntegrityScan.isFullyPresentAndVerified(directory: sandbox.url, pin: pin, repoID: "org/repo"))
    }

    @Test("a tampered file is NOT fully present and verified")
    func tamperedDirectoryIsNotFullyVerified() throws {
        let sandbox = try Sandbox()
        try sandbox.write("poisoned", to: "model.safetensors")
        let pin = Self.pin(contents: ["model.safetensors": "weights!"])

        #expect(!WeightIntegrityScan.isFullyPresentAndVerified(directory: sandbox.url, pin: pin, repoID: "org/repo"))
    }

    @Test("a directory holding a previous pinned revision's weights is NOT fully present and verified")
    func staleRevisionIsNotFullyVerified() throws {
        let sandbox = try Sandbox()
        try sandbox.write("old weights", to: "model.safetensors")
        try sandbox.writeDownloadMetadata(commit: "0000000000000000000000000000000000000000", for: "model.safetensors")
        let pin = Self.pin(
            revision: "1111111111111111111111111111111111111111",
            contents: ["model.safetensors": "new weights"]
        )

        #expect(!WeightIntegrityScan.isFullyPresentAndVerified(directory: sandbox.url, pin: pin, repoID: "org/repo"))
    }

    @Test("a verified directory also leaves a receipt behind, same as enforce")
    func fullyVerifiedWritesReceiptToo() throws {
        let sandbox = try Sandbox()
        try sandbox.write("weights", to: "model.safetensors")
        let pin = Self.pin(contents: ["model.safetensors": "weights"])

        #expect(WeightIntegrityScan.isFullyPresentAndVerified(directory: sandbox.url, pin: pin, repoID: "org/repo"))
        #expect(WeightIntegrityScan.receiptExists(forModelAt: sandbox.url))
    }
}

/// Tiny SHA256 so fixtures compute the same digest the production path does,
/// without the test reaching into CryptoKit's API shape in two places.
private struct SHA256Fixture {
    private var data = Data()
    mutating func update(_ chunk: Data) {
        data.append(chunk)
    }

    func hexDigest() -> String {
        WeightIntegrityScan.sha256Hex(of: data)
    }
}
