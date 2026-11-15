//
//  EmbeddingGemma2ImageDecodeTests.swift
//  M1K3MLXTests
//
//  The decode half of the image path (#836 review fold): ImageIO and CoreGraphics only, no Metal, so it runs
//  under `swift test`. Alpha lands on white, grayscale stays gray, a 1×1 and a tiny image decode and are never
//  upscaled by the decoder, EXIF orientation is applied, corrupt bytes are `invalidImage`, an extreme aspect
//  ratio is refused before its resampling matrix is built, a missing processor config is the vision error, and
//  the memory-pressure watcher's policy (latest target, weak, nothing kept alive).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.8. Prior: none (new file).

import CoreGraphics
import Foundation
import ImageIO
@testable import M1K3MLX
import Testing
import UniformTypeIdentifiers

struct EmbeddingGemma2ImageDecodeTests {
    private func encoded(
        width: Int, height: Int, gray: Bool = false, alpha: Bool = false, type: UTType = .png,
        orientation: Int? = nil, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { _, _ in (200, 30, 30, 255) }
    ) throws -> Data {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let components = gray ? 1 : 4
        var bytes = [UInt8](repeating: 0, count: width * height * components)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (r, g, b, a) = pixel(x, y)
                let at = (y * width + x) * components
                if gray {
                    bytes[at] = r
                } else {
                    // premultiplied, as the context stores it
                    bytes[at] = UInt8(Int(r) * Int(a) / 255)
                    bytes[at + 1] = UInt8(Int(g) * Int(a) / 255)
                    bytes[at + 2] = UInt8(Int(b) * Int(a) / 255)
                    bytes[at + 3] = a
                }
            }
        }
        let info: UInt32 = gray ? CGImageAlphaInfo.none.rawValue
            : (alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        let image = try bytes.withUnsafeMutableBytes { buffer -> CGImage in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * components, space: space, bitmapInfo: info
            ))
            return try #require(context.makeImage())
        }
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private let decode = { (data: Data) throws -> (rgba: [UInt8], height: Int, width: Int) in
        try EmbeddingGemma2ImageProcessor.decode(data, longSide: EmbeddingGemma2ImageProcessor.decodeLongSide)
    }

    @Test("a transparent PNG decodes onto white, an opaque pixel keeps its colour")
    func alphaLandsOnWhite() throws {
        let data = try encoded(width: 4, height: 2, alpha: true) { x, _ in x < 2 ? (0, 0, 0, 0) : (255, 0, 0, 255) }
        let frame = try decode(data)
        #expect(frame.width == 4 && frame.height == 2)
        #expect(Array(frame.rgba[0 ..< 3]) == [255, 255, 255], "transparent → white, not black")
        let opaque = Array(frame.rgba[2 * 4 ..< 2 * 4 + 3])
        #expect(opaque[0] >= 250 && opaque[1] <= 5 && opaque[2] <= 5, "opaque red stays red: \(opaque)")
    }

    @Test("a grayscale PNG decodes to equal R, G and B")
    func grayscale() throws {
        let frame = try decode(encoded(width: 8, height: 8, gray: true) { _, _ in (100, 0, 0, 255) })
        for pixel in stride(from: 0, to: frame.rgba.count, by: 4) {
            #expect(frame.rgba[pixel] == frame.rgba[pixel + 1] && frame.rgba[pixel + 1] == frame.rgba[pixel + 2])
        }
    }

    @Test("a 1×1 image decodes and plans a valid grid; a tiny one is not upscaled by the decoder")
    func tinyImages() throws {
        let one = try decode(encoded(width: 1, height: 1))
        #expect(one.width == 1 && one.height == 1)
        let plan = try EmbeddingGemma2ImageProcessor().resamplePlan(sourceHeight: 1, sourceWidth: 1)
        #expect(plan.height % 48 == 0 && plan.width % 48 == 0 && plan.softTokens >= 1)
        let tiny = try decode(encoded(width: 10, height: 8))
        #expect(tiny.width == 10 && tiny.height == 8, "ImageIO does not upscale below the cap")
        let small = try decode(encoded(width: 100, height: 80))
        #expect(small.width == 100 && small.height == 80)
    }

    @Test("a large image is decoded at its full size, not through a thumbnail filter")
    func fullSize() throws {
        let frame = try decode(encoded(width: 2400, height: 1800, type: .jpeg))
        #expect(frame.width == 2400 && frame.height == 1800)
    }

    @Test("EXIF orientation 6 turns a 300×200 JPEG upright: 200×300")
    func exifOrientation() throws {
        let frame = try decode(encoded(width: 300, height: 200, type: .jpeg, orientation: 6))
        #expect(frame.width == 200 && frame.height == 300)
    }

    @Test("corrupt or empty bytes are invalidImage")
    func corrupt() {
        #expect(throws: EmbeddingGemma2Error.invalidImage) { try decode(Data("not an image".utf8)) }
        #expect(throws: EmbeddingGemma2Error.invalidImage) { try decode(Data()) }
        #expect(throws: EmbeddingGemma2Error.invalidImage) { try decode(Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0])) }
    }

    @Test("an extreme aspect ratio is refused before its resampling matrix is built; a normal photo is not")
    func extremeShapeRefused() throws {
        let processor = EmbeddingGemma2ImageProcessor()
        #expect(throws: EmbeddingGemma2Error.unsupportedImageShape) {
            try processor.resamplePlan(sourceHeight: 1, sourceWidth: 10000)
        }
        #expect(throws: EmbeddingGemma2Error.unsupportedImageShape) {
            try processor.resamplePlan(sourceHeight: 10000, sourceWidth: 1)
        }
        let photo = try processor.resamplePlan(sourceHeight: 3024, sourceWidth: 4032)
        #expect(photo.width == 912 && photo.height == 672 && photo.softTokens == 266)
        // The widest photo the decoder allows still fits the allocation cap.
        _ = try processor.resamplePlan(sourceHeight: 6144, sourceWidth: 8192)
    }

    @Test("a missing processor_config.json is the vision error, not a Foundation one")
    func missingProcessorConfiguration() throws {
        let empty = FileManager.default.temporaryDirectory.appending(component: "eg2-no-processor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: EmbeddingGemma2Error.visionProcessorMissing) {
            try EmbeddingGemma2ImageProcessor.load(directory: empty)
        }
    }

    @Test("the vision errors are distinct cases")
    func distinctErrors() {
        let all: [EmbeddingGemma2Error] = [
            .noVisionTower, .visionWeightsMissing, .visionProcessorMissing, .visionFailed("x"), .invalidImage,
            .unsupportedImageShape, .notEmbeddingGemma2("x"), .unsupportedVision("x"),
        ]
        for (index, error) in all.enumerated() {
            for other in all[(index + 1)...] {
                #expect(error != other)
            }
        }
    }
}

struct VisionPressureReleaseTests {
    final class Fake: VisionUnloadable, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var unloads: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func unloadVision() async {
            lock.withLock { count += 1 }
        }
    }

    @Test("a pressure event unloads the LATEST target only")
    func latestTarget() async {
        let release = VisionPressureRelease()
        let first = Fake(), second = Fake()
        release.watch(first)
        release.watch(second)
        await release.fire()
        #expect(first.unloads == 0)
        #expect(second.unloads == 1)
    }

    @Test("the watcher holds its target weakly: a dropped embedder is gone, and firing is a no-op")
    func weakTarget() async {
        let release = VisionPressureRelease()
        weak var gone: Fake?
        do {
            let target = Fake()
            gone = target
            release.watch(target)
        }
        #expect(gone == nil)
        #expect(release.current == nil)
        await release.fire()
    }

    @Test("the watcher itself is not kept alive by its dispatch source")
    func releasesItself() {
        weak var weakRelease: VisionPressureRelease?
        do {
            let release = VisionPressureRelease()
            weakRelease = release
            release.watch(Fake())
        }
        #expect(weakRelease == nil, "the source's handler holds the watcher weakly, so deinit can cancel it")
    }
}
