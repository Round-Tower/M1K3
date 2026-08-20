//
//  spike-a3-bonjour.swift — Brain-at-Home Phase A, spike A3
//
//  QUESTION: does the gemba pattern port — dnssd DNSServiceRegister
//  (advertise WITHOUT binding, so the real NWListener owns its port) + an
//  NWBrowser round-trip, with TXT carrying protocol version + display name
//  only?
//
//  Run: swift spike-a3-bonjour.swift   (exit 0 = all criteria pass)
//
//  Criteria:
//   1. DNSServiceRegister advertises `_m1k3-spike._tcp` with a TXT record
//   2. NWBrowser finds the service and surfaces the TXT metadata
//   3. teardown: DNSServiceRefDeallocate makes the advertisement vanish
//      (browser reports the service removed)
//
//  Uses a spike-specific type so a stray run never squats the real
//  `_m1k3-brain._tcp` name. macOS local-network privacy may prompt for the
//  hosting terminal on first run — that prompt is itself a finding.
//
//  Signed: Kev + claude-fable-5, 2026-08-19 (scratch spike — no production
//  code; verdict in RESULTS.md). Prior: gemba's BonjourAdvertiser (dnssd).
//

import dnssd
import Foundation
import Network

var failures = 0
func report(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

let serviceType = "_m1k3-spike._tcp"
let serviceName = "M1K3 Spike \(Int.random(in: 1000 ... 9999))"
let servicePort: UInt16 = 47474

// MARK: - Criterion 1: advertise via dnssd with a TXT record

// TXT: version + display name ONLY (never secrets/capabilities — spec §3).
var txt = TXTRecordRef()
TXTRecordCreate(&txt, 0, nil)
_ = "1".withCString { TXTRecordSetValue(&txt, "v", UInt8(strlen($0)), $0) }
_ = "spike".withCString { TXTRecordSetValue(&txt, "name", UInt8(strlen($0)), $0) }

var serviceRef: DNSServiceRef?
let registerError = DNSServiceRegister(
    &serviceRef, 0, 0,
    serviceName, serviceType, nil, nil,
    CFSwapInt16HostToBig(servicePort),
    TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
    nil, nil
)
report("DNSServiceRegister accepted the advertisement", registerError == kDNSServiceErr_NoError,
       "err=\(registerError)")
guard registerError == kDNSServiceErr_NoError, let serviceRef else {
    print("\nA3 VERDICT: FAIL")
    exit(1)
}

DNSServiceSetDispatchQueue(serviceRef, DispatchQueue(label: "spike.a3.dnssd"))

// MARK: - Criterion 2: NWBrowser finds it, TXT included

let browserQueue = DispatchQueue(label: "spike.a3.browser")
let browser = NWBrowser(
    for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
    using: NWParameters()
)
let found = DispatchSemaphore(value: 0)
let removed = DispatchSemaphore(value: 0)
let txtSeen = NSMutableString()

browser.browseResultsChangedHandler = { results, _ in
    for result in results {
        guard case let .service(name, _, _, _) = result.endpoint, name == serviceName else { continue }
        if case let .bonjour(record) = result.metadata {
            txtSeen.setString("v=\(record["v"] ?? "?") name=\(record["name"] ?? "?")")
        }
        found.signal()
        return
    }
    // Our service no longer present → the teardown signal.
    if txtSeen.length > 0 { removed.signal() }
}

browser.start(queue: browserQueue)

let foundOK = found.wait(timeout: .now() + 8) == .success
report("NWBrowser found the advertised service", foundOK)
report("TXT metadata surfaced (version + name only)", txtSeen as String == "v=1 name=spike",
       "saw \"\(txtSeen)\"")

// MARK: - Criterion 3: teardown removes the advertisement

DNSServiceRefDeallocate(serviceRef)
let removedOK = removed.wait(timeout: .now() + 8) == .success
report("deallocating the registration removes the service", removedOK)

browser.cancel()
print(failures == 0 ? "\nA3 VERDICT: PASS (4/4)" : "\nA3 VERDICT: FAIL (\(failures) criteria failed)")
exit(failures == 0 ? 0 : 1)
