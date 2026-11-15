//
//  PCMWave.swift
//  M1K3Eval
//
//  Float samples → a 16-bit mono PCM WAV, for the Kokoro round trip's clips
//  (TTSRoundTripStage writes `clip-<id>.wav` beside its `.txt`, the pair
//  SpeechToTextCorpus reads). Samples clip to [-1, 1].
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.9 (pinned by PCMWaveTests).
//  Prior: none (new file).
//

import Foundation

public enum PCMWave {
    public static func data(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func le32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func le16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        le32(36 + payload)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        le32(16) // fmt chunk size
        le16(1) // PCM
        le16(1) // mono
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * 2)) // byte rate
        le16(2) // block align
        le16(16) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        le32(payload)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            le16(UInt16(bitPattern: Int16((clipped * Float(Int16.max)).rounded())))
        }
        return data
    }
}
