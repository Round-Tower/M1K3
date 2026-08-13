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

        // Lay down the bundle WhisperKit would create for this variant.
        let bundle = base
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-base.en")
            .appendingPathComponent("AudioEncoder.mlmodelc")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(provider.isModelDownloaded) // present → safe to auto-load, no re-download
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
