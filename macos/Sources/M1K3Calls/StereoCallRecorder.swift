//
//  StereoCallRecorder.swift
//  M1K3Calls
//
//  Capture a call as TWO channels — near-end mic (left) + far-end system audio
//  (right, via a Core Audio process tap) — muxed into one stereo file. The
//  StereoChannelDiarizer then reads channel == speaker, so a live recording is
//  speaker-attributed with no ML. If the system-audio tap can't start, it
//  degrades GRACEFULLY to a mono mic recording (diarizer returns no turns →
//  unattributed transcript, never a failure); a refused System Audio Recording
//  permission leaves the far channel silent (see SystemAudioTap).
//
//  Verify-by-launch: the process tap + the mic engine + the audio-capture TCC prompt
//  need a real device and a live call — none of it runs headless. The file write
//  is now in CallAudioWriter (atomic + validated, unit-tested). This adapter is the
//  OS glue, kept defensive (mono fallback) so a capture fault can't lose a recording.
//
//  start()/stop() stay async: the mic permission request is async, and callers
//  already await them.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-07, Confidence 0.55, Prior: Unknown
//  Review: claude-opus-4-8, 2026-06-09 (PR #10) — stop() now atomically claims the
//  stop inside the lock before async teardown, so two concurrent stops can't both
//  reach removeTap(onBus:) and trap; writeFile guards rather than force-unwraps.
//  Review: claude-opus-4-8, 2026-06-21 — the inline writeFile handed AVAudioFile an
//  INTERLEAVED buffer that didn't match its processingFormat, so every recording
//  wrote ZERO frames (captured audio, saved silence — the "recorded, nothing
//  appeared" bug). Write moved to CallAudioWriter: deinterleaved buffer in the file's
//  processingFormat, written to a .partial, frame-count validated, then atomically
//  renamed — so an empty or interrupted write never surfaces as a recording.
//  Review: Kev + claude-opus-5.5, 2026-09-23 — the far end moves from ScreenCaptureKit
//  to a Core Audio process tap (SystemAudioTap). SCK held the SCREEN RECORDING
//  permission and ran a throwaway 2×2 video stream just to hear system audio; App
//  Review asked what M1K3 does with screen recordings. The tap asks only for System
//  Audio Recording (NSAudioCaptureUsageDescription), excludes M1K3's own process, and
//  is converted to 48 kHz mono like the mic. Confidence now 0.7 (verify-by-launch).

// NOT @preconcurrency (dropped 2026-07-16, proven dead by full-SIL compile on all
// three SDKs): the attribute was blanket-suppressing Sendable diagnostics in the
// one file that smuggles AVAudioPCMBuffer/AVAudioEngine (non-Sendable in SDK 26)
// across a Sendable boundary — exactly where the next careless capture needs the
// compiler to shout, not stay silent.
import AVFoundation
import Foundation
import os

// Far-end (system-audio) capture is a Core Audio process tap, which is macOS-only — it
// has no iOS/visionOS equivalent (ReplayKit is a different, foreground-consent model).
// The whole recorder is guarded so the M1K3Calls library compiles on iOS/visionOS;
// the shared adaptive shell reaches call-recording only on macOS. On mobile the
// feature is simply absent (a Phase-2 decision, not a silent stub).
// Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.8, Prior: Kev + claude-opus-4-8
#if os(macOS)

    /// Records a stereo call (mic + system audio). `@unchecked Sendable`: mutable
    /// capture state is guarded by `lock`; the tap/engine callbacks append under it.
    public final class StereoCallRecorder: NSObject, @unchecked Sendable {
        /// Common capture format both sources are normalised to before interleaving.
        private static let sampleRate: Double = 48000
        /// Diagnostic trail for QA — `log stream --predicate 'subsystem == "app.m1k3"'`.
        /// Metadata only (formats, counts, sizes, errors); never the audio itself.
        private static let log = Logger(subsystem: "app.m1k3", category: "calls")

        private let lock = NSLock()
        private let engine = AVAudioEngine()
        private var tap: SystemAudioTap?
        private var farConverter: AVAudioConverter?
        private var nearSamples: [Float] = []
        private var farSamples: [Float] = []
        private var recording = false
        private var micConverter: AVAudioConverter?

        public var isRecording: Bool {
            lock.withLock { recording }
        }

        /// Start both captures. The mic is required; system audio is best-effort —
        /// if it can't start, we still record mono (so the call is never lost).
        /// - Returns: whether the far-end (system audio) channel is being captured.
        @discardableResult
        public func start() async throws -> Bool {
            Self.log.notice("start requested")
            _ = await stop() // reset any prior session

            try await startMic()
            lock.withLock { recording = true }

            do {
                try await startSystemAudio()
                Self.log.notice("capturing stereo (mic + system audio)")
                return true
            } catch {
                // The tap couldn't be built (no output device, Core Audio refusal) → mono mic only.
                Self.log.notice("system audio unavailable → mono mic only: \(error, privacy: .public)")
                return false
            }
        }

        /// Stop both captures and write the interleaved stereo (or mono) file.
        public func stop() async -> URL? {
            // Atomically claim the stop before any async teardown. Two concurrent stops
            // (double-tap, or a consent-timeout racing a user tap) must not both reach
            // removeTap(onBus:) — removing a tap from a bus with none installed traps.
            let claimed = lock.withLock { () -> Bool in
                guard recording else { return false }
                recording = false
                return true
            }
            guard claimed else { return nil }

            lock.withLock { tap }?.stop()
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)

            let (near, far) = lock.withLock {
                let result = (nearSamples, farSamples)
                tap = nil
                farConverter = nil
                nearSamples = []
                farSamples = []
                micConverter = nil
                return result
            }
            Self.log.notice("stopped: near=\(near.count, privacy: .public) far=\(far.count, privacy: .public) samples")
            guard !near.isEmpty || !far.isEmpty else {
                Self.log.error("nothing captured — no file written (mic delivered 0 samples)")
                return nil
            }
            do {
                let url = try CallAudioWriter.write(near: near, far: far, sampleRate: Self.sampleRate)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
                Self.log.notice("wrote \(bytes ?? -1, privacy: .public) bytes → \(url.lastPathComponent, privacy: .public)")
                return url
            } catch {
                // Keep the specific cause (.formatUnavailable vs .writeFailed) — a disk
                // fault must not be mis-reported to the user as a mic-permission problem.
                let total = near.count + far.count
                Self.log.error("write failed despite \(total, privacy: .public) captured samples: \(error, privacy: .public)")
                return nil
            }
        }

        // MARK: - Mic (near-end, left)

        private func startMic() async throws {
            // Mic permission must be SETTLED before we touch the inputNode. On the first
            // launch under a new signing identity the TCC grant isn't established yet, and
            // `outputFormat(forBus:)` in that state returns a degenerate 0-Hz format.
            // Handing that to `installTap` invalidates the HAL AudioUnit
            // (kAudioUnitErr_InvalidElement, -10877) and the recording captures nothing —
            // so request first, then read the format.
            guard await Self.micAuthorized() else {
                Self.log.error("mic permission denied — recording aborted")
                throw RecorderError.micPermissionDenied
            }

            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            Self.log.notice("mic input format \(inFormat.sampleRate, privacy: .public)Hz ch=\(inFormat.channelCount, privacy: .public)")
            // Even with permission granted, refuse a degenerate format rather than crash
            // the HAL — installTap with a 0-Hz clock is the direct trigger for -10877.
            guard inFormat.sampleRate > 0 else {
                Self.log.error("degenerate 0-Hz input format — refusing to install tap (would throw -10877)")
                throw RecorderError.formatUnavailable
            }
            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate, channels: 1, interleaved: false
            ) else { throw RecorderError.formatUnavailable }
            // AVAudioConverter is nil for an invalid format pair; a silently-nil converter
            // would drop every buffer and yield an empty recording.
            guard let converter = AVAudioConverter(from: inFormat, to: target) else {
                throw RecorderError.formatUnavailable
            }
            lock.withLock { micConverter = converter }

            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
                guard let self else { return }
                let samples = Self.convert(buffer, to: target, using: self.converter())
                guard !samples.isEmpty else { return }
                self.lock.withLock { self.nearSamples.append(contentsOf: samples) }
            }
            engine.prepare()
            try engine.start()
        }

        private func converter() -> AVAudioConverter? {
            lock.withLock { micConverter }
        }

        /// Microphone authorization (macOS TCC). Requests on first use; the prompt uses
        /// NSMicrophoneUsageDescription. Returns false if denied/restricted so the caller
        /// surfaces a readable error instead of recording silence.
        private static func micAuthorized() async -> Bool {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        }

        // MARK: - System audio (far-end, right)

        private func startSystemAudio() async throws {
            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate, channels: 1, interleaved: false
            ) else { throw RecorderError.formatUnavailable }
            // Publish BEFORE starting: a stop() racing this start then finds the tap
            // and tears it down (SystemAudioTap makes the later start a no-op),
            // instead of missing a device that went live a few instructions later.
            let tap = SystemAudioTap()
            lock.withLock { self.tap = tap }
            try tap.start { [weak self] buffer in
                guard let self else { return }
                let samples = Self.convert(buffer, to: target, using: self.farConverter(for: buffer.format, to: target))
                guard !samples.isEmpty else { return }
                self.lock.withLock { self.farSamples.append(contentsOf: samples) }
            }
        }

        /// The tap's format is only known once it runs (the output device's rate):
        /// build the converter on the first buffer, reuse it after. Allocation happens
        /// OUTSIDE the lock the mic tap also takes (the mic path's own rule).
        private func farConverter(for format: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
            if let cached = lock.withLock({ farConverter }), cached.inputFormat == format { return cached }
            let built = AVAudioConverter(from: format, to: target)
            lock.withLock { farConverter = built }
            return built
        }

        // MARK: - File output

        /// Convert a captured PCM buffer to mono Float32 at the common rate → samples.
        private static func convert(
            _ buffer: AVAudioPCMBuffer,
            to format: AVAudioFormat,
            using converter: AVAudioConverter?
        ) -> [Float] {
            guard let converter else { return [] }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }

            // Hand the converter the buffer exactly once. A reference box dodges the
            // Swift 6 "captured var in concurrent code" warning (the block runs
            // synchronously inside convert(), but its type is treated as Sendable).
            let pending = InputBox(buffer)
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                guard let next = pending.take() else { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData
                return next
            }
            guard error == nil, let channel = out.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        }

        public enum RecorderError: Error, Sendable, LocalizedError {
            case formatUnavailable
            case micPermissionDenied

            public var errorDescription: String? {
                switch self {
                case .formatUnavailable:
                    String(localized: "The microphone isn’t ready yet — try again in a moment.")
                case .micPermissionDenied:
                    String(localized: "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone.")
                }
            }
        }

        /// One-shot holder for the converter's input buffer (Sendable so the input
        /// block can capture it without a strict-concurrency warning).
        private final class InputBox: @unchecked Sendable {
            private var buffer: AVAudioPCMBuffer?
            init(_ buffer: AVAudioPCMBuffer) {
                self.buffer = buffer
            }

            func take() -> AVAudioPCMBuffer? {
                defer { buffer = nil }
                return buffer
            }
        }
    }

#endif
