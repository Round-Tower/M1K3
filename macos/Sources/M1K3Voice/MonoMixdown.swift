//
//  MonoMixdown.swift
//  M1K3Voice
//
//  Tap-side downmix for multi-channel input devices. SFSpeech accepts
//  >2-channel buffers and then silently never produces a partial — no error,
//  no transcript, "it just continues to listen" (Kev's 9-channel aggregate,
//  2026-08-14). VPIO would normally render the mic mono, but voice processing
//  doesn't engage on aggregate devices (AppleSpeechTranscriber's own
//  enableVoiceProcessing note), so the tap sees the raw device format.
//
//  Channels are SUMMED, not averaged: on an aggregate device the live mic is
//  ONE channel beside silent siblings, and averaging would divide real speech
//  by the channel count (a ninth of the amplitude on Kev's device). Summing is
//  WhisperKit's own default ChannelMode; the clamp keeps correlated channels
//  from clipping. Mono and stereo pass through untouched — the class that has
//  always worked stays byte-identical.
//
//  Split on the house line: `mix` is the pure DSP (unit-tested on plain
//  arrays); `mixIfNeeded` is the AVAudioPCMBuffer adapter, verify-by-launch
//  like the transcriber it serves. (A first cut tested the adapter with real
//  AVAudioPCMBuffers and segfaulted the PARALLEL test run — constructing
//  layout-backed CoreAudio buffers across concurrent suites is not a
//  supported test harness; don't reintroduce it.)
//
//  Signed: Kev + claude-fable-5, 2026-08-14, Confidence 0.85 (core pinned on
//  arrays; the adapter is mechanical pointer glue and the live-device proof
//  is the deploy). Prior: Unknown.

import AVFoundation

/// Sum >2-channel float32 buffers down to mono so the recognizer can hear them.
public enum MonoMixdown {
    /// Pure core: sum per-frame across channels, clamped to [-1, 1].
    /// Expects equal-length channels; frames beyond a short channel read as
    /// absent. Empty input → empty output.
    public static func mix(_ channels: [[Float]]) -> [Float] {
        guard let frames = channels.map(\.count).max(), frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)
        for channel in channels {
            for (index, sample) in channel.enumerated() {
                out[index] += sample
            }
        }
        return out.map { min(1.0, max(-1.0, $0)) }
    }

    /// Buffer adapter: returns the buffer itself for 1–2 channels (or any
    /// shape it can't read); otherwise a fresh mono buffer at the same sample
    /// rate and frame length, produced by `mix`.
    public static func mixIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channelCount > 2, frames > 0,
              let source = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: buffer.format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let out = mono.floatChannelData
        else { return buffer }

        let mixed = mix((0 ..< channelCount).map { channel in
            Array(UnsafeBufferPointer(start: source[channel], count: frames))
        })
        mono.frameLength = buffer.frameLength
        for (index, sample) in mixed.enumerated() {
            out[0][index] = sample
        }
        return mono
    }
}
