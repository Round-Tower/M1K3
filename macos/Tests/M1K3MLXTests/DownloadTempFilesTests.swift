//
//  DownloadTempFilesTests.swift
//  M1K3MLXTests
//
//  Kev's iPhone, 2026-10-30: "Lil download still hangs at 1%". It wasn't hung: URLSession's download
//  task was writing `tmp/CFNetworkDownload_*.tmp` at 7 MB/s while the bar measured only the repo
//  folder, so a 3 GB file read as 1% until the last second. Attempts that died left their temp file
//  behind, 1.4 GB in one case, and the next attempt started again. These pin what counts as live.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-30, Confidence 0.85 (pure; measured on the device first).
//  Prior: none (new file).
//

import Foundation
@testable import M1K3MLX
import Testing

struct DownloadTempFilesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ name: String, _ bytes: Int, age: TimeInterval) -> DownloadTempFiles.File {
        DownloadTempFiles.File(name: name, bytes: bytes, modified: now.addingTimeInterval(-age))
    }

    @Test("a file still being written counts towards the bar")
    func liveFileCounts() {
        let files = [file("CFNetworkDownload_LLDr7P.tmp", 1_500_000_000, age: 2)]
        #expect(DownloadTempFiles.liveBytes(files, now: now) == 1_500_000_000)
    }

    @Test("a stray from a dead attempt doesn't count: the bar would start at 50% and lie the other way")
    func strayDoesNotCount() {
        let files = [
            file("CFNetworkDownload_old.tmp", 1_400_000_000, age: 3600),
            file("CFNetworkDownload_new.tmp", 10_000_000, age: 1),
        ]
        #expect(DownloadTempFiles.liveBytes(files, now: now) == 10_000_000)
    }

    @Test("only URLSession's download files count, whatever else tmp holds")
    func otherFilesDoNotCount() {
        let files = [file("export.pdf", 5_000_000, age: 1), file("hf-download-1.tmp", 5_000_000, age: 1)]
        #expect(DownloadTempFiles.liveBytes(files, now: now) == 0)
    }

    @Test("a live file past a slow patch still counts: the window outlasts a network stall")
    func slowPatch() {
        let files = [file("CFNetworkDownload_a.tmp", 100, age: DownloadTempFiles.liveWindow - 1)]
        #expect(DownloadTempFiles.liveBytes(files, now: now) == 100)
    }

    @Test("strays over an hour old are the ones to clear; a recent one may still be in use")
    func strays() {
        let files = [
            file("CFNetworkDownload_old.tmp", 1, age: 3601),
            file("CFNetworkDownload_recent.tmp", 1, age: 600),
            file("export.pdf", 1, age: 86400),
        ]
        #expect(DownloadTempFiles.strays(files, now: now).map(\.name) == ["CFNetworkDownload_old.tmp"])
    }

    @Test("the bar never runs backwards: a stall past the live window keeps the last reading")
    func barHoldsItsHighWaterMark() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/M1K3MLX/HuggingFaceBridge.swift"), encoding: .utf8
        )
        #expect(source.contains("let bytes = max(inFlightBytes(url), cached?.bytes ?? 0)"))
    }

    @Test("strays clear before the verified-copy exit: a phone with its brain installed holds them too")
    func clearsBeforeTheFastPath() throws {
        // Kev's phone kept its 1.85 GB after Lil landed, because every later load left on the fast path.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/M1K3MLX/HuggingFaceBridge.swift"), encoding: .utf8
        )
        let clear = try #require(source.range(of: "Self.removeStrayTempFiles()"))
        let exit = try #require(source.range(of: "if Self.shouldSkipNetworkFetch("))
        #expect(clear.lowerBound < exit.lowerBound)
    }
}
