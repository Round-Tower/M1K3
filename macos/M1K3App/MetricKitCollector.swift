//
//  MetricKitCollector.swift
//  M1K3App
//
//  Subscribes MXMetricManager and persists each MXDiagnosticPayload/
//  MXMetricPayload's raw JSON to a bounded on-disk store under Application
//  Support/M1K3/metrickit/. Nothing here ever leaves the device — the
//  existing "Report an issue" flow is the one deliberate egress path
//  (IssueReporter.swift), and even there only DIGEST summary lines travel
//  (M1K3Diagnostics.MetricPayloadDigest), never the raw payload JSON.
//
//  Platform coverage — VERIFIED against the macOS 26.5 SDK headers
//  (`MetricKit.framework/Headers/*.h`), not assumed:
//    - `MXMetricManagerSubscriber` / `MXDiagnosticPayload` / `MXMetricPayload`:
//      all `API_AVAILABLE(macos(12.0))` or lower — well under this app's
//      macOS 26 floor.
//    - `crashDiagnostics`, `hangDiagnostics`, `cpuExceptionDiagnostics`, and
//      `diskWriteExceptionDiagnostics` on `MXDiagnosticPayload` carry NO
//      platform override — all four are available on macOS.
//    - The ONE diagnostic macOS does NOT get is `appLaunchDiagnostics`
//      (`API_AVAILABLE(ios(16.0)) API_UNAVAILABLE(macos, tvos, watchos)`).
//      So macOS coverage is not narrower for the classes this app cares about
//      (crash/hang/cpu-exception/disk-write) — only app-launch diagnostics
//      are iOS-exclusive, and this collector simply never sees that array on
//      the Mac (no special-casing needed).
//
//  Registration (`add(_:)`) is documented as a lightweight subscription —
//  payloads arrive later via the delegate callbacks (at most once/day) plus
//  whatever's already queued in `pastPayloads`/`pastDiagnosticPayloads` since
//  the last launch — so calling `start()` from `AppEnvironment.init` is cheap
//  and non-blocking.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.8 (SDK-header-
//  verified platform coverage; delivery cadence + the undocumented JSON shape
//  are Apple's own internals — real payloads are verify-by-crash/-by-launch).
//  Prior: Unknown.
//

import Foundation
import M1K3Diagnostics
import M1K3LogCore
import MetricKit

/// Subscribes `MXMetricManager` for the process lifetime and persists each
/// payload's JSON to a bounded on-disk store. A singleton — like
/// `MXMetricManager.shared` itself, there's exactly one OS-level subscription
/// to make per process, so there's no benefit to per-instance state here.
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitCollector()

    /// A "few MB" bound per the #86 spec — payloads are typically a few KB
    /// of JSON each, so 50 files is generous headroom while keeping the
    /// directory listing itself cheap.
    private static let fileCap = 50

    private let directory: URL
    private let log = M1K3Log.logger(.metricKit)

    override private init() {
        directory = Self.resolveDirectory()
        super.init()
    }

    /// Subscribe, then ingest anything already queued from before this
    /// launch (e.g. a crash from the last session) immediately rather than
    /// waiting for the next daily delivery.
    func start() {
        MXMetricManager.shared.add(self)
        for payload in MXMetricManager.shared.pastDiagnosticPayloads {
            persist(payload.jsonRepresentation(), kindPrefix: "diagnostic")
        }
        for payload in MXMetricManager.shared.pastPayloads {
            persist(payload.jsonRepresentation(), kindPrefix: "metric")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            persist(payload.jsonRepresentation(), kindPrefix: "diagnostic")
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            persist(payload.jsonRepresentation(), kindPrefix: "metric")
        }
    }

    /// The most recent digest SUMMARY LINES (kind/date/version/top-frame —
    /// never raw payload text), newest first, for the opt-in "Report an
    /// issue" inclusion.
    func recentDigestLines(limit: Int = 10) -> [String] {
        existingFiles()
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .compactMap { entry -> String? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(entry.name)) else { return nil }
                return MetricPayloadDigest.summarize(data).line
            }
    }

    private func persist(_ data: Data, kindPrefix: String) {
        let name = "\(kindPrefix)-\(Int(Date().timeIntervalSince1970 * 1000)).json"
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            log.error("metrickit persist failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        prune()
        // Kind + a fixed breadcrumb only — never the payload's own content
        // (house rule: length + brain, never the text).
        let kind = MetricPayloadDigest.summarize(data).kind
        log.notice("metrickit payload stored: \(kind.rawValue, privacy: .public)")
    }

    private func prune() {
        let toDelete = MetricRetentionPolicy.filesToPrune(existingFiles(), cap: Self.fileCap)
        for name in toDelete {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func existingFiles() -> [MetricStoreFile] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return urls.compactMap { url in
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return MetricStoreFile(name: url.lastPathComponent, date: date)
        }
    }

    private static func resolveDirectory() -> URL {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("M1K3/metrickit", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
