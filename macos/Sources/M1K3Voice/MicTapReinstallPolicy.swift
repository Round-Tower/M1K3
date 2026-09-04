//
//  MicTapReinstallPolicy.swift
//  M1K3Voice
//
//  What to do when the audio engine posts `.AVAudioEngineConfigurationChange`
//  under a live mic tap. The handler used to answer "tear down and reinstall"
//  every time — right for a real route change (a Bluetooth headset's HFP switch
//  takes the mic from 48 kHz to 16 kHz and the old tap goes deaf), wasteful for
//  the notification the iPhone posts ~0.5 s after the FIRST arm of every voice
//  session, where the format read back is identical: two `stt mic input format`
//  lines in the log and an engine bounce for nothing (2026-09-03, iPhone 17
//  Pro). Pure, so the three answers are pinned by tests; the AVFoundation-facing
//  code only reads two numbers off the node and asks.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-04, Confidence 0.85 (the table is
//  the handler's old behaviour split by "did the format actually change"; the
//  `.restart` leg honours Apple's contract that the engine may stop itself
//  before posting — verify-by-launch on the phone decides whether a kept tap
//  keeps delivering). Prior: Unknown.

import Foundation

/// The two numbers a tap is bound to. `AVAudioFormat` stays in the
/// AVFoundation-facing code; the policy only needs what decides the answer.
public struct MicTapFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channelCount: UInt32

    public init(sampleRate: Double, channelCount: UInt32) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public enum MicTapReinstallPolicy {
    public enum Action: Equatable, Sendable {
        /// Format unchanged and the engine is still running: the tap is fine.
        case keep
        /// Format unchanged but the engine stopped itself (Apple's documented
        /// behaviour before posting): start it again, leave the tap alone.
        case restart
        /// The format really changed, or there is no tap on record: the old
        /// tap is bound to a dead format — remove, reinstall, restart.
        case reinstall
    }

    public static func action(
        installed: MicTapFormat?, current: MicTapFormat, engineRunning: Bool
    ) -> Action {
        guard let installed, installed == current else { return .reinstall }
        return engineRunning ? .keep : .restart
    }
}
