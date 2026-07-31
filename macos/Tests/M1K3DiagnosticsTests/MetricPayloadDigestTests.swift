//
//  MetricPayloadDigestTests.swift
//  M1K3DiagnosticsTests
//
//  MetricKit's JSONRepresentation() isn't a documented, versioned schema — this
//  pins the digest's best-effort reading of the well-known key NAMES (crash/hang/
//  cpu/disk-write diagnostic arrays, timeStampBegin/End, appVersion, binaryName)
//  against hand-built fixtures shaped like Apple's real payload JSON, not the
//  other way round. A miss here degrades a summary line, never leaks payload text.
//

import Foundation
@testable import M1K3Diagnostics
import Testing

struct MetricPayloadDigestTests {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    @Test("a crash payload is identified, with date/version/top-frame extracted")
    func crashPayload() {
        let json = """
        {
          "timeStampBegin": "2026-07-29T00:00:00Z",
          "timeStampEnd": "2026-07-30T00:00:00Z",
          "crashDiagnostics": [
            {
              "diagnosticMetaData": { "appVersion": "1.4.0", "appBuildVersion": "88" },
              "callStackTree": {
                "callStacks": [
                  { "callStackRootFrames": [ { "binaryName": "M1K3", "address": 123 } ] }
                ]
              }
            }
          ]
        }
        """
        let summary = MetricPayloadDigest.summarize(data(json))
        #expect(summary.kind == .crash)
        #expect(summary.appVersion == "1.4.0")
        #expect(summary.topFrame == "M1K3")
        #expect(summary.date != nil)
    }

    @Test("a hang-only payload is identified as .hang")
    func hangPayload() {
        let json = """
        { "timeStampBegin": "2026-07-29T00:00:00Z",
          "hangDiagnostics": [ { "diagnosticMetaData": { "appVersion": "1.4.0" } } ] }
        """
        #expect(MetricPayloadDigest.summarize(data(json)).kind == .hang)
    }

    @Test("a cpu-exception-only payload is identified as .cpuException")
    func cpuExceptionPayload() {
        let json = """
        { "cpuExceptionDiagnostics": [ { "diagnosticMetaData": {} } ] }
        """
        #expect(MetricPayloadDigest.summarize(data(json)).kind == .cpuException)
    }

    @Test("a disk-write-exception-only payload is identified as .diskWriteException")
    func diskWriteExceptionPayload() {
        let json = """
        { "diskWriteExceptionDiagnostics": [ { "diagnosticMetaData": {} } ] }
        """
        #expect(MetricPayloadDigest.summarize(data(json)).kind == .diskWriteException)
    }

    @Test("an app-launch-only payload (iOS-only in practice) is identified as .appLaunch")
    func appLaunchPayload() {
        let json = """
        { "appLaunchDiagnostics": [ { "diagnosticMetaData": {} } ] }
        """
        #expect(MetricPayloadDigest.summarize(data(json)).kind == .appLaunch)
    }

    @Test("a payload with only a time range and no diagnostic arrays is .metrics")
    func metricsPayload() {
        let json = """
        { "timeStampBegin": "2026-07-29T00:00:00Z", "timeStampEnd": "2026-07-30T00:00:00Z",
          "metaData": { "appVersion": "1.4.0" } }
        """
        #expect(MetricPayloadDigest.summarize(data(json)).kind == .metrics)
    }

    @Test("empty diagnostic arrays don't count — falls through to the next check")
    func emptyArraysFallThrough() {
        let json = """
        { "crashDiagnostics": [], "hangDiagnostics": [],
          "timeStampBegin": "2026-07-29T00:00:00Z" }
        """
        #expect(MetricPayloadDigest.summarize(data(json)).kind == .metrics)
    }

    @Test("garbage / non-JSON data summarizes as .unknown with no fields")
    func garbageData() {
        let summary = MetricPayloadDigest.summarize(Data("not json at all".utf8))
        #expect(summary.kind == .unknown)
        #expect(summary.date == nil)
        #expect(summary.appVersion == nil)
        #expect(summary.topFrame == nil)
    }

    @Test("crash takes priority over hang when both arrays are present")
    func priorityOrdering() {
        let json = """
        { "crashDiagnostics": [ { "diagnosticMetaData": {} } ],
          "hangDiagnostics": [ { "diagnosticMetaData": {} } ] }
        """
        #expect(MetricPayloadDigest.summarize(data(json)).kind == .crash)
    }

    @Test("the NSDate-description date shape ('yyyy-MM-dd HH:mm:ss Z') also parses")
    func nsDateDescriptionShapeDate() {
        let json = """
        { "crashDiagnostics": [ { "diagnosticMetaData": {} } ],
          "timeStampBegin": "2026-07-29 00:00:00 +0000" }
        """
        #expect(MetricPayloadDigest.summarize(data(json)).date != nil)
    }

    @Test("appVersion is found even when nested inside an array of diagnostics")
    func nestedAppVersion() {
        let json = """
        { "hangDiagnostics": [
            { "diagnosticMetaData": { "appBuildVersion": "12" } },
            { "diagnosticMetaData": { "appVersion": "2.0.1" } }
          ] }
        """
        #expect(MetricPayloadDigest.summarize(data(json)).appVersion == "2.0.1")
    }

    @Test("a payload with no binaryName anywhere has a nil topFrame")
    func noTopFrame() {
        let json = """
        { "hangDiagnostics": [ { "diagnosticMetaData": { "appVersion": "1.0" } } ] }
        """
        #expect(MetricPayloadDigest.summarize(data(json)).topFrame == nil)
    }

    @Test("the summary line is bounded and human-readable with all fields present")
    func lineAllFields() {
        let summary = MetricPayloadSummary(
            kind: .crash,
            date: Date(timeIntervalSince1970: 0),
            appVersion: "1.4.0",
            topFrame: "M1K3"
        )
        let line = summary.line
        #expect(line.hasPrefix("crash · "))
        #expect(line.contains("v1.4.0"))
        #expect(line.hasSuffix("M1K3"))
    }

    @Test("the summary line degrades gracefully when only kind is known")
    func lineKindOnly() {
        let summary = MetricPayloadSummary(kind: .unknown, date: nil, appVersion: nil, topFrame: nil)
        #expect(summary.line == "unknown")
    }
}
