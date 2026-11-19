//
//  CallAudioWriter.swift
//  M1K3Calls
//
//  Write captured near/far mono channels to a validated stereo `.caf` — atomically.
//  The previous inline writer handed AVAudioFile an INTERLEAVED buffer that didn't
//  match the file's processingFormat, so every write produced ZERO frames: a
//  recording that "happened" but held no audio (the symptom behind "I recorded a
//  call and nothing appeared"). It also created the destination file BEFORE writing,
//  leaving an orphaned 0-frame `.caf` whenever a write failed.
//
//  This fills a NON-interleaved buffer in the file's own processingFormat (the .caf
//  on disk is still interleaved — AVAudioFile converts on write), writes to a
//  `.partial` sibling, confirms real frames, then atomically renames into place. A
//  `defer` removes the partial on every failure path, so the only file that ever
//  appears is a real recording. Channels are filled directly here — no interleaver.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-21, Confidence 0.85, Prior: Unknown
//  Review: claude-opus-5-5, 2026-11-19 — localisation Phase 0: the error text resolves from M1K3Calls' catalog
//  (`bundle: .module`). English unchanged.
//

// NOT @preconcurrency (dropped 2026-07-16, proven dead by full-SIL compile on all
// three SDKs) — see StereoCallRecorder for the rationale.
import AVFoundation
import Foundation

public enum CallAudioWriterError: Error, Sendable, LocalizedError {
    /// Nothing was captured (both channels empty) — no file is written.
    case emptyCapture
    /// The OS couldn't build the audio format/buffer for the write.
    case formatUnavailable
    /// The file wrote but held zero frames, or couldn't be finalised — the
    /// partial is removed so no orphan is left behind.
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .emptyCapture:
            String(localized: "No audio was captured.", bundle: .module)
        case .formatUnavailable:
            String(localized: "The audio format isn’t available.", bundle: .module)
        case .writeFailed:
            String(localized: "The recording couldn’t be saved.", bundle: .module)
        }
    }
}

public enum CallAudioWriter {
    /// Write two mono channels (near → ch0/left/"Speaker 1", far → ch1/right/
    /// "Speaker 2") to a validated stereo `.caf`. The shorter side is silence-padded
    /// so the two stay time-aligned; the StereoChannelDiarizer reads channel ==
    /// speaker straight off this file. With one channel empty it's a silence-paired
    /// (effectively mono) recording.
    /// - Throws: `.emptyCapture` when there are no samples; `.formatUnavailable` /
    ///   `.writeFailed` on an OS write fault (no orphan file is ever left behind).
    /// - Returns: the URL of the finished recording inside `directory`.
    @discardableResult
    public static func write(
        near: [Float],
        far: [Float],
        sampleRate: Double,
        in directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let frames = max(near.count, far.count)
        guard frames > 0 else { throw CallAudioWriterError.emptyCapture }

        // Standard (non-interleaved) Float32 stereo. The buffer we write MUST be in
        // the file's own processingFormat — handing AVAudioFile an interleaved buffer
        // it doesn't expect writes ZERO frames (the original silent-empty-file bug).
        guard let fileFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: 2, interleaved: false
        ) else { throw CallAudioWriterError.formatUnavailable }

        let partial = directory.appendingPathComponent("m1k3-call-\(UUID().uuidString).caf.partial")
        // The only file that survives is the renamed final one — a successful
        // moveItem leaves nothing at `partial`, so this is a no-op on success and a
        // guaranteed cleanup on every throw/early-return below.
        defer { try? FileManager.default.removeItem(at: partial) }

        do {
            // AVAudioFile flushes + closes on deinit, so scope the write so the file
            // is finalised before we validate + move it.
            let file = try AVAudioFile(forWriting: partial, settings: fileFormat.settings)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(frames)
            ), let channels = buffer.floatChannelData else {
                throw CallAudioWriterError.formatUnavailable
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            for frame in 0 ..< frames {
                channels[0][frame] = frame < near.count ? near[frame] : 0
                channels[1][frame] = frame < far.count ? far[frame] : 0
            }
            try file.write(from: buffer)
        } catch let error as CallAudioWriterError {
            throw error // propagate the precise cause (.formatUnavailable) honestly
        } catch {
            throw CallAudioWriterError.writeFailed
        }

        // Guard the silent zero-frame write (and the crash-mid-write orphan) — only a
        // file with real frames is allowed to surface as a recording.
        guard validFrameCount(at: partial) > 0 else { throw CallAudioWriterError.writeFailed }

        let finalURL = directory.appendingPathComponent("m1k3-call-\(UUID().uuidString).caf")
        do {
            try FileManager.default.moveItem(at: partial, to: finalURL)
        } catch {
            throw CallAudioWriterError.writeFailed
        }
        return finalURL
    }

    /// Frame count of a written file, or 0 if it can't be opened — the validation
    /// hook that refuses to return a zero-frame recording as success.
    private static func validFrameCount(at url: URL) -> Int64 {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return file.length
    }
}
