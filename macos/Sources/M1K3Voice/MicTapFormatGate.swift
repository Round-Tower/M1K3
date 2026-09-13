//
//  MicTapFormatGate.swift
//  M1K3Voice
//
//  The one decision that keeps a live mic tap from going silently deaf: is the
//  input format the audio engine handed us actually usable? `AVAudioEngine`'s
//  `inputNode.outputFormat(forBus:0)` returns a DEGENERATE 0-Hz / 0-channel
//  format when the route hasn't settled — a Bluetooth (HFP) mic still engaging,
//  or mic TCC not yet granted. Installing a tap with that format invalidates the
//  HAL AudioUnit (kAudioUnitErr_InvalidElement, -10877) and the recogniser
//  captures nothing. StereoCallRecorder already refuses it inline; this lifts the
//  same guard to a pure, testable predicate the live STT path can share.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.85, Prior: Unknown
//  (mirrors the StereoCallRecorder.startMic 0-Hz guard, 2026-06-12).
//  Review: Kev + claude-opus-5, 2026-09-13 — tapSampleRate: the tap takes the HARDWARE
//  rate (a stale 44.1k node read-back against a 48k mic aborted voice mode). Confidence now 0.85.

import Foundation

/// Pure guard: a tap-able input format needs a real clock and at least one
/// channel. Anything else is a route that hasn't come up — refuse it rather than
/// install a dead tap that yields no audio (the BLE/-10877 silent-capture bug).
public enum MicTapFormatGate {
    public static func isUsable(sampleRate: Double, channelCount: UInt32) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    /// The sample rate a mic tap must be installed at. AVAudioEngine insists the
    /// tap's rate equals the input HARDWARE rate and raises an uncaught
    /// NSException (an abort Swift cannot catch) when they differ. The node's
    /// `outputFormat(forBus:)` can lag the hardware — 2026-09-13 it read 44.1 kHz
    /// against a 48 kHz mic right after a 44.1 kHz TTS queue, and the app
    /// aborted entering voice mode. So the hardware rate wins; the node's rate
    /// only fills in when the hardware reports nothing. Nil = no usable rate.
    public static func tapSampleRate(nodeRate: Double, hardwareRate: Double) -> Double? {
        if hardwareRate > 0 { return hardwareRate }
        return nodeRate > 0 ? nodeRate : nil
    }
}
