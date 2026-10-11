//
//  WhisperKitProviderTests.swift
//  M1K3WhisperKitTests
//
//  WhisperKit is a CoreML/mic OS adapter — model download + live transcription
//  are verified by launching the app, not here. We pin the deterministic parts:
//  identity, the "unavailable until a model loads" contract, and that it slots
//  into the TranscriptionProvider seam (the routing logic is tested in M1K3Voice).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — P1: a partial WhisperKit folder is not
//  "downloaded"; the completion marker and the legacy complete-looking install. Confidence 0.85.

import Foundation
import M1K3Voice
@testable import M1K3WhisperKit
import Testing

struct WhisperKitProviderTests {
    @Test("has the expected stable name")
    func name() {
        #expect(WhisperKitProvider().name == "WhisperKit")
    }

    @Test("is unavailable until a model is loaded")
    func unavailableBeforeModelLoad() {
        // No prepareModel call → no model → router should prefer Apple Speech.
        #expect(WhisperKitProvider().isAvailable == false)
    }

    @Test("starting without a loaded model throws, not crashes")
    func startWithoutModelThrows() {
        #expect(throws: WhisperKitProviderError.self) {
            _ = try WhisperKitProvider().startListening()
        }
    }

    @Test("isModelDownloaded reflects the CoreML bundle on disk — the launch-restore guard")
    func modelDownloadedDetection() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-wk-\(UUID().uuidString)", isDirectory: true)
        let provider = WhisperKitProvider(model: "base.en", downloadBase: base)
        #expect(provider.isModelDownloaded == false) // nothing on disk yet

        // Lay down what WhisperKit creates for this variant, complete.
        try Self.layDownCompleteModel(model: "base.en", base: base)
        #expect(provider.isModelDownloaded) // present → safe to auto-load, no re-download
    }

    /// An older, complete-looking install: every top-level artifact, but no completion marker.
    private static func layDownCompleteModel(model: String, base: URL) throws {
        let folder = try #require(WhisperKitProvider.modelFolder(model: model, downloadBase: base))
        for bundle in ["AudioEncoder", "MelSpectrogram", "TextDecoder"] {
            let dir = folder.appendingPathComponent("\(bundle).mlmodelc")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("coremldata.bin"))
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
    }

    @Test("P1: a partial download (AudioEncoder alone, mid-fetch) is NOT downloaded")
    func partialDownloadIsNotInstalled() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-wk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = try #require(WhisperKitProvider.modelFolder(model: "small.en", downloadBase: base))
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("AudioEncoder.mlmodelc"), withIntermediateDirectories: true
        )
        #expect(!WhisperKitProvider.isModelDownloaded(model: "small.en", downloadBase: base))
        // Even with most artifacts present, a missing one keeps it partial.
        try Self.layDownCompleteModel(model: "small.en", base: base)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("TextDecoder.mlmodelc"))
        #expect(!WhisperKitProvider.isModelDownloaded(model: "small.en", downloadBase: base))
    }

    @Test("P1: the completion marker settles it; an older complete-looking install needs no marker")
    func completionMarker() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-wk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = try #require(WhisperKitProvider.modelFolder(model: "base.en", downloadBase: base))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Marker alone (written only after WhisperKit.download returned) counts.
        try WhisperKitProvider.markDownloadComplete(inFolder: folder)
        #expect(WhisperKitProvider.isModelDownloaded(model: "base.en", downloadBase: base))
        // Legacy: complete artifacts, no marker.
        try Self.layDownCompleteModel(model: "small.en", base: base)
        #expect(WhisperKitProvider.isModelDownloaded(model: "small.en", downloadBase: base))
    }

    @Test("#567 follow-up: the completion marker lands in the folder WhisperKit.download RETURNED")
    func markerGoesInTheReturnedFolder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-wk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A returned folder that is NOT the computed one (the kit moved its layout).
        let returned = base.appendingPathComponent("elsewhere/openai_whisper-base.en", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: true)
        try WhisperKitProvider.markDownloadComplete(inFolder: returned)
        let marker = returned.appendingPathComponent(WhisperKitProvider.completionMarkerName)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        // …and nothing was written under the computed folder.
        let computed = try #require(WhisperKitProvider.modelFolder(model: "base.en", downloadBase: base))
        #expect(!FileManager.default.fileExists(atPath: computed.path))
    }

    @Test("removeDownloadedModel deletes exactly one variant's folder and tolerates a missing one")
    func removeDownloadedModelIsScoped() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-wk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for variant in ["base.en", "small.en"] {
            try Self.layDownCompleteModel(model: variant, base: base)
        }
        try WhisperKitProvider.removeDownloadedModel(model: "base.en", downloadBase: base)
        #expect(!WhisperKitProvider.isModelDownloaded(model: "base.en", downloadBase: base))
        #expect(WhisperKitProvider.isModelDownloaded(model: "small.en", downloadBase: base))
        try WhisperKitProvider.removeDownloadedModel(model: "base.en", downloadBase: base) // already gone
        try WhisperKitProvider.removeDownloadedModel(model: "base.en", downloadBase: nil)
    }

    @Test("conforms to TranscriptionProvider and slots into a router")
    func conformsToSeam() {
        let provider: any TranscriptionProvider = WhisperKitProvider()
        let router = TranscriptionRouter(providers: [provider])
        // Unavailable (no model) → router resolves nothing, no crash.
        #expect(router.activeProvider == nil)
    }

    // MARK: - Input-device channel gate (the 2026-08-13 silent-dictation incident)

    @Test("a multi-channel input device makes the provider report device-unusable")
    func multiChannelDeviceVetoes() {
        let provider = WhisperKitProvider(inputChannelCount: { 9 })
        #expect(provider.inputDeviceUsable == false)
    }

    @Test("mono and stereo devices keep the provider device-usable")
    func monoStereoDevicesServe() {
        #expect(WhisperKitProvider(inputChannelCount: { 1 }).inputDeviceUsable)
        #expect(WhisperKitProvider(inputChannelCount: { 2 }).inputDeviceUsable)
    }

    @Test("an unreadable probe fails open — availability still gates on the model")
    func unknownProbeFailsOpen() {
        let provider = WhisperKitProvider(inputChannelCount: { nil })
        #expect(provider.inputDeviceUsable)
        // Still unavailable overall: no model is loaded.
        #expect(provider.isAvailable == false)
    }

    @Test("the device probe is cached — isAvailable is on a SwiftUI hot path")
    func probeResultIsCached() {
        // canDictate → router → isAvailable re-evaluates per coalesced render
        // during streaming; the CoreAudio HAL read must not run each time.
        let calls = ProbeCallCounter()
        let provider = WhisperKitProvider(inputChannelCount: {
            calls.increment()
            return 2
        })
        #expect(provider.inputDeviceUsable)
        #expect(provider.inputDeviceUsable)
        #expect(provider.inputDeviceUsable)
        #expect(calls.count == 1)
    }
}

/// Thread-safe call counter for the @Sendable probe closure.
private final class ProbeCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}
