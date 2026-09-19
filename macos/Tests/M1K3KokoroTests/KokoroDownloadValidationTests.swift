//
//  KokoroDownloadValidationTests.swift
//  M1K3KokoroTests
//
//  Pins the two validation seams that keep a bad download from permanently
//  bricking the neural voice (2026-07-16 concurrency deep pass, finding 12/32):
//
//  1. HTTP status validation — URLSession treats a 404/503 as a COMPLETED
//     download (didCompleteWithError is nil), so without a status check the
//     error body gets staged as kokoro-v1.0.onnx, `prepare()` short-circuits on
//     file-existence forever, and every utterance silently falls back to the
//     Apple voice with no retry path.
//  2. Staged-file plausibility floor — catches the status-check-proof failure
//     class (captive portal returning 200 + HTML) AND self-heals installs
//     already poisoned in the field: an implausibly small stage is deleted and
//     re-downloaded instead of being trusted forever.
//
//  Signed: Kev + claude-fable-5, 2026-07-16, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3Kokoro
import Testing

struct KokoroDownloadValidationTests {
    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/kokoro-v1.0.onnx")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    @Test("2xx responses are acceptable")
    func acceptsSuccessStatuses() {
        #expect(KokoroDownloadValidation.isAcceptable(httpResponse(status: 200)))
        #expect(KokoroDownloadValidation.isAcceptable(httpResponse(status: 206)))
    }

    @Test("HTTP error statuses are rejected — an error page must never be staged as weights")
    func rejectsErrorStatuses() {
        #expect(!KokoroDownloadValidation.isAcceptable(httpResponse(status: 404)))
        #expect(!KokoroDownloadValidation.isAcceptable(httpResponse(status: 429)))
        #expect(!KokoroDownloadValidation.isAcceptable(httpResponse(status: 503)))
    }

    @Test("non-HTTP responses pass through — status validation is an HTTP concern")
    func acceptsNonHTTPResponse() {
        let fileResponse = URLResponse(
            url: URL(fileURLWithPath: "/tmp/kokoro-v1.0.onnx"),
            mimeType: nil,
            expectedContentLength: 0,
            textEncodingName: nil
        )
        #expect(KokoroDownloadValidation.isAcceptable(fileResponse))
        #expect(KokoroDownloadValidation.isAcceptable(nil))
    }

    @Test("a staged file below its size floor is implausible")
    func rejectsUndersizedStage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let staged = dir.appendingPathComponent("kokoro-v1.0.onnx")
        try Data("<html>404 Not Found</html>".utf8).write(to: staged)

        #expect(!KokoroDownloadValidation.isPlausibleStage(staged, floorBytes: 1024))
    }

    @Test("a staged file at or above its floor is plausible")
    func acceptsPlausibleStage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let staged = dir.appendingPathComponent("voices-v1.0.bin")
        try Data(repeating: 0, count: 2048).write(to: staged)

        #expect(KokoroDownloadValidation.isPlausibleStage(staged, floorBytes: 2048))
    }

    @Test("a missing file is not a plausible stage")
    func rejectsMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).onnx")
        #expect(!KokoroDownloadValidation.isPlausibleStage(missing, floorBytes: 1))
    }

    @Test("the production floors reject error pages but sit far below the real payloads")
    func productionFloors() {
        // Weights ~156 MB, voices ~28 MB. Floors only need to reject staged HTML
        // error bodies (a few KB) with a huge margin in both directions.
        #expect(KokoroDownloadValidation.modelFloorBytes == 50 * 1024 * 1024)
        #expect(KokoroDownloadValidation.voicesFloorBytes == 1024 * 1024)
        // config.json is itself only a few KB — this floor just catches a
        // zero-byte/truncated write; the HTTP status gate is the real defense.
        #expect(KokoroDownloadValidation.configFloorBytes == 200)
    }

    @Test("a download whose awaiting task is already cancelled throws CancellationError, never staging a file")
    func cancelledDownloadThrowsWithoutStaging() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.bin")
        try Data(repeating: 7, count: 512).write(to: source)
        let dest = dir.appendingPathComponent("dest.bin")

        // The cancellation must not depend on URLSession delegate-callback
        // ordering after cancel() — the pre-cancelled entry path resumes the
        // continuation itself, so this is deterministic, not timing-dependent.
        let download = Task { () -> Result<Void, Error> in
            while !Task.isCancelled {
                await Task.yield()
            }
            do {
                try await FileDownloader.download(source, to: dest) { _ in }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        download.cancel()
        let outcome = await download.value

        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("a file URL download completes and stages the payload (the delegate happy path)")
    func fileURLDownloadStages() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.bin")
        let payload = Data(repeating: 42, count: 2048)
        try payload.write(to: source)
        let dest = dir.appendingPathComponent("dest.bin")

        try await FileDownloader.download(source, to: dest) { _ in }

        #expect(try Data(contentsOf: dest) == payload)
    }
}
