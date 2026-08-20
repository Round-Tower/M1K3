//
//  BrainAdvertiser.swift
//  M1K3BrainServe
//
//  Bonjour advertisement for the Brain at Home listener — the gemba
//  advertise-WITHOUT-binding pattern (dnssd DNSServiceRegister), so the
//  NWListener keeps sole ownership of its socket. Spike A3 proved the
//  round-trip incl. clean removal on deallocate.
//
//  TXT carries protocol version + display name ONLY (SPEC §3) — never
//  secrets, never capability details. Discovery is untrusted UI hinting;
//  authentication is the PSK handshake, full stop.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.85 (a straight
//  lift of the passing spike; verify-by-launch on the app path). Prior:
//  spikes/spike-a3-bonjour.swift + gemba's BonjourAdvertiser.
//

import dnssd
import Foundation
import os

public final class BrainAdvertiser: @unchecked Sendable {
    public static let serviceType = "_m1k3._tcp"

    private static let log = Logger(subsystem: "app.m1k3", category: "brain-serve")
    private let lock = NSLock()
    private var serviceRef: DNSServiceRef?
    private let queue = DispatchQueue(label: "app.m1k3.brain-advertise")

    public init() {}

    /// Advertise (idempotent — restarts on repeat). Returns false when dnssd
    /// refuses; the listener keeps serving either way (discovery is a hint).
    @discardableResult
    public func start(name: String, port: UInt16, version: String = "1") -> Bool {
        stop()
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        _ = version.withCString { TXTRecordSetValue(&txt, "v", UInt8(strlen($0)), $0) }
        _ = name.withCString { TXTRecordSetValue(&txt, "name", UInt8(strlen($0)), $0) }

        var ref: DNSServiceRef?
        let error = DNSServiceRegister(
            &ref, 0, 0,
            name, Self.serviceType, nil, nil,
            CFSwapInt16HostToBig(port),
            TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
            nil, nil
        )
        guard error == kDNSServiceErr_NoError, let ref else {
            Self.log.error("brain advertise failed: dnssd err \(error)")
            return false
        }
        DNSServiceSetDispatchQueue(ref, queue)
        lock.withLock { serviceRef = ref }
        Self.log.notice("brain advertise: \(Self.serviceType) \"\(name, privacy: .public)\" :\(port)")
        return true
    }

    public func stop() {
        let ref = lock.withLock { () -> DNSServiceRef? in
            let current = serviceRef
            serviceRef = nil
            return current
        }
        if let ref { DNSServiceRefDeallocate(ref) }
    }

    deinit { stop() }
}
