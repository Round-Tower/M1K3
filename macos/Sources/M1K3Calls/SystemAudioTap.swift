//
//  SystemAudioTap.swift
//  M1K3Calls
//
//  The far end of a call — system audio — through a Core Audio process tap
//  (macOS 14.2+): a mono global tap that excludes M1K3's own process (so its
//  voice never lands in the recording), wrapped in a private aggregate device
//  whose IO proc hands buffers to the recorder.
//
//  Why this and not ScreenCaptureKit: SCK can only deliver system audio as a
//  side channel of a SCREEN capture, so the app held the Screen Recording
//  permission (and ran a 2×2 video stream it threw away) to hear the other
//  side of a call. App Review, fairly, asked what M1K3 does with screen
//  recordings. A process tap asks for exactly what is used — the "System
//  Audio Recording Only" permission, NSAudioCaptureUsageDescription — and
//  never touches the screen.
//
//  One behaviour to know: if the user refuses the permission, the tap still
//  starts and delivers SILENCE (macOS offers no public preflight). The
//  recording then carries a silent far channel — the same file a refused
//  Screen Recording grant produced — and the diarizer attributes every turn
//  to the near end. The mic channel is never affected.
//
//  Verify-by-launch: the TCC dialog, the tap and the aggregate device need a
//  real Mac with something playing; none of it runs headless.
//
//  Signed: Kev + claude-opus-5.5, 2026-09-23, Confidence 0.75 (the Core Audio
//  object dance follows Apple's "Capturing system audio with Core Audio taps"
//  sample; verified by launch under the App Sandbox on macOS 27 — see PR).
//  Prior: none (new file).
//

#if os(macOS)
    import AVFoundation
    import CoreAudio
    import Foundation
    import os

    /// A running system-audio tap. `start` builds it, `stop` tears every Core
    /// Audio object down in reverse order. Not reusable: make a new one per call.
    /// `@unchecked Sendable`: the Core Audio object IDs are only touched under
    /// `stateLock`, and a `stop` that lands first makes a later `start` a no-op —
    /// so start/stop from different tasks can't race or orphan a live device.
    final class SystemAudioTap: @unchecked Sendable {
        private static let log = Logger(subsystem: "app.m1k3", category: "calls")

        private var tapID = AudioObjectID(kAudioObjectUnknown)
        private var aggregateID = AudioObjectID(kAudioObjectUnknown)
        private var procID: AudioDeviceIOProcID?
        private let queue = DispatchQueue(label: "app.m1k3.systemaudiotap")
        private let stateLock = NSLock()
        private var stopped = false

        enum TapError: Error {
            case coreAudio(String, OSStatus)
            case unsupportedFormat
        }

        /// Start the tap; `onBuffer` receives each IO cycle's audio (tap format,
        /// on a private queue). Throws — and leaves nothing behind — on failure.
        func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            try stateLock.withLock {
                guard !stopped else { return }
                do {
                    try build(onBuffer: onBuffer)
                } catch {
                    teardown()
                    throw error
                }
            }
        }

        private func build(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            // 1. The tap: everything the Mac plays, minus M1K3 itself.
            let excluded = Self.ownProcessObject().map { [$0] } ?? []
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
            description.uuid = UUID()
            description.name = "M1K3 call (far end)"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try Self.check("create process tap", AudioHardwareCreateProcessTap(description, &tapID))

            // 2. The tap's own stream format (the output device's rate, Float32, mono).
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var formatAddress = Self.address(kAudioTapPropertyFormat)
            try Self.check("read tap format", AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd))
            guard let format = AVAudioFormat(streamDescription: &asbd) else { throw TapError.unsupportedFormat }

            // 3. A private aggregate device clocked by the default output, carrying the tap.
            let outputUID = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "M1K3 call capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            try Self.check(
                "create aggregate device",
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
            )

            // 4. The IO proc: wrap each input buffer list (no copy) and hand it on.
            try Self.check("create IO proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
                _, input, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
                else { return }
                onBuffer(buffer)
            })
            try Self.check("start aggregate device", AudioDeviceStart(aggregateID, procID))
            Self.log.notice("system-audio tap running: \(format.sampleRate, privacy: .public)Hz ch=\(format.channelCount, privacy: .public)")
        }

        /// Tear down in reverse order; safe on a half-built tap and when called twice.
        func stop() {
            stateLock.withLock {
                stopped = true
                teardown()
            }
        }

        private func teardown() {
            if aggregateID != kAudioObjectUnknown {
                if let procID {
                    AudioDeviceStop(aggregateID, procID)
                    AudioDeviceDestroyIOProcID(aggregateID, procID)
                }
                AudioHardwareDestroyAggregateDevice(aggregateID)
            }
            if tapID != kAudioObjectUnknown {
                AudioHardwareDestroyProcessTap(tapID)
            }
            procID = nil
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        // MARK: - Core Audio helpers

        private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        }

        private static func check(_ step: String, _ status: OSStatus) throws {
            guard status == noErr else { throw TapError.coreAudio(step, status) }
        }

        /// M1K3's own Core Audio process object, so its speech is left out of
        /// the far channel. Nil (exclude nothing) if the HAL doesn't know us yet.
        private static func ownProcessObject() -> AudioObjectID? {
            var pid = ProcessInfo.processInfo.processIdentifier
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
            )
            return status == noErr && object != kAudioObjectUnknown ? object : nil
        }

        private static func defaultOutputUID() throws -> String {
            var device = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            try check("read default output", AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
            ))
            var uid: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            address = Self.address(kAudioDevicePropertyDeviceUID)
            try check("read output UID", AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid))
            guard let uid else { throw TapError.coreAudio("read output UID", -1) }
            return uid.takeRetainedValue() as String
        }
    }
#endif
