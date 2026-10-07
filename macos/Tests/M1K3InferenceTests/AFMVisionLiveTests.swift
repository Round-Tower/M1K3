//
//  AFMVisionLiveTests.swift
//  M1K3InferenceTests
//
//  Live, opt-in (`M1K3_AFM_EVAL=1`): can Mini actually SEE? The 2026-10-06 vision baseline put Mini
//  at 1/16 — every answer a confident confabulation — while Big scored 14/16 on the same images.
//  The app sends images as `Attachment(imageURL:)`, a file URL handed to an out-of-process model.
//  This asks Mini about a fixture with a known answer two ways, unsandboxed: by URL and by decoded
//  CGImage. Both right → AFM can see, and the app's sandboxed URL hand-off is the suspect. Both
//  wrong → it's AFM's vision, not our plumbing.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.7, Prior: none (new file).

import CoreGraphics
import Foundation
import ImageIO
import Testing
#if canImport(FoundationModels)
    @_weakLinked import FoundationModels
#endif

@Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_AFM_EVAL"] == "1"), .serialized)
struct AFMVisionLiveTests {
    /// receipt-cafe.png's total is 23.40 by construction (tools/eval/make_vision_fixtures.swift).
    private static let receipt = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/M1K3Eval/Resources/VisionFixtures/receipt-cafe.png")
    private static let question = "What's the total on this receipt? Reply with just the amount."

    #if compiler(>=6.4) && canImport(FoundationModels)
        @Test("Mini reads the receipt total by URL and by CGImage (prints both answers)")
        func miniReadsTheReceipt() async throws {
            guard #available(macOS 27.0, *) else { return }
            let availability = SystemLanguageModel.default.availability
            print("AFM-VISION availability=\(availability)")
            try #require(SystemLanguageModel.default.isAvailable, "Apple Intelligence: \(availability)")
            try #require(FileManager.default.fileExists(atPath: Self.receipt.path))

            let byURL = try await LanguageModelSession().respond {
                Self.question
                Attachment(imageURL: Self.receipt)
            }.content

            let source = try #require(CGImageSourceCreateWithURL(Self.receipt as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let byImage = try await LanguageModelSession().respond {
                Self.question
                Attachment(image)
            }.content

            print("AFM-VISION url=\(byURL.debugDescription) cgimage=\(byImage.debugDescription)")
            // The record is the printed pair; the expectation pins the CGImage path, which never
            // depends on another process reading our files.
            #expect(byImage.contains("23.40") || byImage.contains("23,40"), "cgimage: \(byImage)")
        }
    #endif
}
