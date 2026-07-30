//
//  AppCore+MetricKit.swift
//  M1K3iOS / M1K3visionOS
//
//  The mobile shell's own MetricKit subscriber. AppCore.swift's header notes
//  this shell deliberately does NOT touch the macOS AppEnvironment and has no
//  test bundle by design, so this is a small, separate collector (mirroring
//  M1K3App/MetricKitCollector.swift) rather than a shared app-target type —
//  it reuses the SAME pure decision logic (M1K3Diagnostics.MetricPayloadDigest
//  / MetricRetentionPolicy), just with its own thin MXMetricManagerSubscriber
//  glue, because M1K3App and M1K3iOSApp are separate compiled targets/apps.
//
//  Both iOS and visionOS ship MetricKit.framework (verified: both SDKs carry
//  `MetricKit.framework`; the framework's availability macros are `ios()`-
//  keyed with no `xros()` override, and visionOS inherits iOS availability in
//  that case — this app's 26.0 floor is well above every MetricKit minimum).
//
//  v1 surfacing is minimal on mobile (no "Report an issue" flow exists here
//  yet) — persist + a `.notice` count line is the whole story, matching the
//  task's documented fallback for a shell whose report-flow doesn't exist.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.75 (compile-verified
//  only — mirrors the SDK-header-verified Mac collector's shape; on-device
//  delivery is verify-by-crash like the Mac side, and mobile has no
//  MXMetricManagerSubscriber smoke test of its own by design). Prior: Unknown.
//

import Foundation
import M1K3Diagnostics
import MetricKit
import os

/// Subscribes `MXMetricManager` for the process lifetime and persists each
/// payload's JSON to a bounded on-disk store under Application Support/
/// M1K3/metrickit/. A singleton, same reasoning as the Mac's collector.
final class MobileMetricKitCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MobileMetricKitCollector()

    private static let fileCap = 50

    private let directory: URL
    private let log = Logger(subsystem: "app.m1k3", category: "metric-kit")

    override private init() {
        directory = Self.resolveDirectory()
        super.init()
    }

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

    private func persist(_ data: Data, kindPrefix: String) {
        let name = "\(kindPrefix)-\(Int(Date().timeIntervalSince1970 * 1000)).json"
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            log.error("metrickit persist failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        prune()
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

extension AppCore {
    /// Subscribe MXMetricManager once at launch — cheap + synchronous
    /// (registration only; payloads arrive later via the delegate callbacks).
    func startMetricKitCollection() {
        MobileMetricKitCollector.shared.start()
    }
}
