//
//  ConverterChannelGateTests.swift
//  M1K3WhisperKitTests
//
//  Pins the channel-count rule that kept Kev's dictation silent on 2026-08-13:
//  WhisperKit's AudioProcessor builds a LAYOUTLESS AVAudioFormat for its mic
//  converter, and AVFoundation refuses those above 2 channels — so a 9-channel
//  aggregate input device throws "Failed to create node format" on every start.
//  The gate is what lets `isAvailable` report the truth so the router slides to
//  Apple Speech instead of dying silently.
//
//  Signed: Kev + claude-fable-5, 2026-08-13, Confidence 0.9 (the 9-channel case
//  is the live incident, read off the unified log). Prior: Unknown.

@testable import M1K3WhisperKit
import Testing

struct ConverterChannelGateTests {
    @Test("mono and stereo devices can serve")
    func monoAndStereoServe() {
        #expect(ConverterChannelGate.canServe(channelCount: 1))
        #expect(ConverterChannelGate.canServe(channelCount: 2))
    }

    @Test("multi-channel devices are refused — the layoutless-format wall")
    func multiChannelRefused() {
        #expect(!ConverterChannelGate.canServe(channelCount: 3))
        // The live incident: a 9-channel aggregate device, 2026-08-13 22:53.
        #expect(!ConverterChannelGate.canServe(channelCount: 9))
    }

    @Test("zero channels is a dead route, not a servable one")
    func zeroChannelsRefused() {
        #expect(!ConverterChannelGate.canServe(channelCount: 0))
    }

    @Test("an unknown probe fails OPEN — never disable WhisperKit on ignorance")
    func unknownProbeFailsOpen() {
        #expect(ConverterChannelGate.canServe(channelCount: nil))
    }
}
