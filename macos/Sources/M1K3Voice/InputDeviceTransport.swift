//
//  InputDeviceTransport.swift
//  M1K3Voice
//
//  Whether the system's default INPUT device is a Bluetooth one — the one fact
//  `VoiceProcessingPolicy` needs from the hardware. macOS only (CoreAudio's
//  device tree); the mobile shells return nil and the policy never asks.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85 (a two-property
//  CoreAudio read, checked against `system_profiler SPAudioDataType` on this
//  Mac with a Sony headset: "blue"). Prior: Unknown.
//

import Foundation
#if os(macOS)
    import CoreAudio
#endif

public enum InputDeviceTransport {
    /// The system's current default INPUT device id, or nil off-macOS / on a
    /// failed read. `AVAudioEngine` binds its input node to whatever device is
    /// resolved at engine-init and does NOT follow a later default change — on
    /// this Mac it inherited a multi-channel system aggregate that STARVES the
    /// recogniser (ch=7/9, `audioDuration 0`), while the headset the user
    /// actually selected sits unused. Re-pinning the input node to this id per
    /// listen keeps the engine on the real device (2026-09-12).
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        #if os(macOS)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
            ) == noErr, device != 0 else { return nil }
            return device
        #else
            return nil
        #endif
    }

    /// A device's human name (for the diagnostic log), or nil.
    public static func deviceName(_ device: AudioDeviceID) -> String? {
        #if os(macOS)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var size = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &name) {
                AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
            }
            return status == noErr ? (name as String) : nil
        #else
            return nil
        #endif
    }

    /// `true` for a Bluetooth (HFP/LE) default input, `false` for anything else
    /// readable, `nil` when the transport can't be read (no input device, a
    /// property failure) — the policy treats nil as "not Bluetooth".
    public static func defaultInputIsBluetooth() -> Bool? {
        #if os(macOS)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
            ) == noErr, device != 0 else { return nil }
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport = UInt32(0)
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                device, &transportAddress, 0, nil, &transportSize, &transport
            ) == noErr else { return nil }
            return transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
        #else
            return nil
        #endif
    }
}
