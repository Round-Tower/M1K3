//
//  ConverterChannelGate.swift
//  M1K3WhisperKit
//
//  Whether WhisperKit's live mic path can serve the current input device.
//
//  WhisperKit's `AudioProcessor.setupEngine` (checkout, ~line 987) builds its
//  tap format with `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)`
//  — the LAYOUTLESS initializer, which AVFoundation only honours for 1–2
//  channels. On a multi-channel input device (Kev's 9-channel aggregate,
//  2026-08-13) it returns nil and every stream start throws "Failed to create
//  node format" — dictation dies silently while Apple Speech (whose VPIO path
//  renders mono) works fine. `setupEngine` is internal upstream, so the fix
//  from out here is honesty, not surgery: report the device unusable and let
//  the availability-ordered TranscriptionRouter slide to Apple Speech.
//
//  nil (probe couldn't read the device) fails OPEN: wrongly vetoing would
//  disable WhisperKit everywhere the probe is unsupported, while wrongly
//  allowing merely reproduces the old behaviour — and the failure is loud in
//  the log either way.
//
//  Signed: Kev + claude-fable-5, 2026-08-13, Confidence 0.9 (constraint
//  verified against the WhisperKit checkout and the live incident log).
//  Prior: Unknown.

/// Pure predicate: can WhisperKit's layoutless converter format be built for a
/// device with this many input channels?
enum ConverterChannelGate {
    static func canServe(channelCount: UInt32?) -> Bool {
        guard let channelCount else { return true }
        return channelCount >= 1 && channelCount <= 2
    }
}
