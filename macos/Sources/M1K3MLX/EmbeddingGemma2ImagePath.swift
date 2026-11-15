//
//  EmbeddingGemma2ImagePath.swift
//  M1K3MLX
//
//  How an image reaches EmbeddingGemma 2's vision tower (#836): decode, size, resample, and the token
//  layout around the soft tokens. The model card is explicit that task prefixes apply to text only
//  ("pass images, video and audio without any prefix"), so an image's sequence is
//  `<bos> <boi> <image>×n <eoi> <eos>` — no prompt text. That layout is the image path's own prompt
//  version (`image-v2`, which also covers the preprocessing), kept in its own fingerprint beside the text path's `prompt-v1`.
//
//  Upstream credit (MIT): the size arithmetic and the antialiased-bicubic weights follow
//  ml-explore/mlx-swift-lm PR #684 (`Libraries/MLXVLM/EmbeddingGemma2.swift`, `Gemma4ProcessorConfiguration`;
//  Copyright © 2026 Apple Inc.), which in turn reproduce the checkpoint's `Gemma4ImageProcessor`
//  (Pillow / torchvision resampling, a = -0.5). Differences: ImageIO instead of Core Image for decoding
//  (no `CIContext`; the orientation transform and the sRGB conversion come from ImageIO), and the resample
//  is two plain matrix products per channel instead of a Metal kernel — slower on a 12 MP photo, flat in
//  memory, and the same arithmetic. Pillow reads the file's pixels without colour management; ImageIO
//  converts to sRGB, so a wide-gamut photo differs from the Python reference by its profile, an sRGB
//  image by nothing.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.75. Prior: none (new file; #836).
//  Review: Kev + claude-opus-5.5, 2026-11-15 (#836 review fold) — Pillow's resample order (horizontal, round, vertical,
//  round), one resample only (full-size decode to an 8,192 px safety cap), a cap on the weight allocation, the version
//  string covers preprocessing (image-v2).
//  Open: the numeric proof is EmbeddingGemma2RefStage's (12 drawings against mlx-vlm); no photo has been
//  through it, and the resample speed on a 12 MP photo is unmeasured on the phone.

import CoreGraphics
import Foundation
import ImageIO
import MLX

// MARK: - Sizing

/// The image processor's arithmetic: the aspect-preserving size, the soft-token count and the resampling weights.
public struct EmbeddingGemma2ImageProcessor: Sendable, Equatable {
    public let patchSize: Int
    public let poolingKernelSize: Int
    /// Soft tokens per image at most (the model card's default is 280; 70 to 1120 are supported).
    public let maxSoftTokens: Int

    /// The longest side ImageIO will decode: a safety cap, not a resample. A photo within it is decoded at its
    /// full size, so the only resample is ours (a thumbnail filter followed by our bicubic would filter twice
    /// and move the vector off the reference). 8,192 px is a 200 MB RGBA bitmap; larger images are scaled DOWN
    /// to it by ImageIO, which is a divergence from the reference only for a frame over ~50 MP.
    static let decodeLongSide = 8192

    public init(patchSize: Int = 16, poolingKernelSize: Int = 3, maxSoftTokens: Int = 280) {
        self.patchSize = patchSize
        self.poolingKernelSize = poolingKernelSize
        self.maxSoftTokens = maxSoftTokens
    }

    /// Reads the `image_processor` block of `processor_config.json`. Throws if the processor normalises
    /// (the vision tower expects raw 0...1 pixels) or its numbers cannot make a grid.
    public init(processorConfiguration data: Data) throws {
        struct Block: Decodable {
            let doNormalize: Bool?
            let maxSoftTokens: Int?
            let patchSize: Int?
            let poolingKernelSize: Int?

            enum CodingKeys: String, CodingKey {
                case doNormalize = "do_normalize"
                case maxSoftTokens = "max_soft_tokens"
                case patchSize = "patch_size"
                case poolingKernelSize = "pooling_kernel_size"
            }
        }
        struct Root: Decodable {
            let imageProcessor: Block

            enum CodingKeys: String, CodingKey {
                case imageProcessor = "image_processor"
            }
        }
        let block = try JSONDecoder().decode(Root.self, from: data).imageProcessor
        let patch = block.patchSize ?? 16
        let pool = block.poolingKernelSize ?? 3
        let budget = block.maxSoftTokens ?? 280
        guard block.doNormalize != true, patch > 0, pool > 0, budget > 0 else {
            throw EmbeddingGemma2Error.unsupportedVision("image processor configuration")
        }
        self.init(patchSize: patch, poolingKernelSize: pool, maxSoftTokens: budget)
    }

    /// Reads `processor_config.json` from a checkpoint directory; a missing or unreadable file is
    /// `visionProcessorMissing`, not a raw Foundation error.
    static func load(directory: URL) throws -> EmbeddingGemma2ImageProcessor {
        let data: Data
        do {
            data = try Data(contentsOf: directory.appending(component: "processor_config.json"))
        } catch {
            throw EmbeddingGemma2Error.visionProcessorMissing
        }
        return try EmbeddingGemma2ImageProcessor(processorConfiguration: data)
    }

    /// The largest size that keeps the aspect, stays within `maxSoftTokens × pool²` patches, and has both
    /// sides a multiple of `pool × patch` (so the pooling cells cover the image exactly). One side flooring
    /// to zero (an extreme aspect) clamps to one cell and caps the long side at the token budget.
    public func targetSize(height: Int, width: Int) -> (height: Int, width: Int) {
        let side = poolingKernelSize * patchSize
        let patches = maxSoftTokens * poolingKernelSize * poolingKernelSize
        let target = Double(patches * patchSize * patchSize)
        let factor = (target / Double(max(height * width, 1))).squareRoot()
        var cellsHigh = Int((factor * Double(height) / Double(side)).rounded(.down))
        var cellsWide = Int((factor * Double(width) / Double(side)).rounded(.down))
        if cellsHigh == 0 {
            cellsHigh = 1
            cellsWide = max(min(Int((Double(width) / Double(max(height, 1))).rounded(.down)), maxSoftTokens), 1)
        } else if cellsWide == 0 {
            cellsWide = 1
            cellsHigh = max(min(Int((Double(height) / Double(max(width, 1))).rounded(.down)), maxSoftTokens), 1)
        }
        return (cellsHigh * side, cellsWide * side)
    }

    /// The soft tokens the tower produces for an image of exactly `height × width` pixels.
    public func softTokenCount(height: Int, width: Int) -> Int {
        let cell = poolingKernelSize * patchSize
        precondition(height % cell == 0 && width % cell == 0, "a target size is a multiple of pool × patch")
        return (height / patchSize) * (width / patchSize) / (poolingKernelSize * poolingKernelSize)
    }

    /// `[output × input]` row-major weights of the antialiased bicubic filter (a = -0.5) that Pillow and
    /// torchvision use: the filter widens by the shrink factor, and each row is normalised to sum to 1.
    static func bicubicWeights(input: Int, output: Int) -> [Float] {
        let scale = Double(input) / Double(output)
        let filterScale = max(scale, 1)
        let support = 2 * filterScale
        var weights = [Float](repeating: 0, count: output * input)
        for row in 0 ..< output {
            let center = (Double(row) + 0.5) * scale
            let first = max(Int(center - support + 0.5), 0)
            let last = min(Int(center + support + 0.5), input)
            guard first < last else { continue }
            let taps = (first ..< last).map { cubic((Double($0) - center + 0.5) / filterScale) }
            let total = taps.reduce(0, +)
            guard total != 0 else { continue }
            for (offset, tap) in taps.enumerated() {
                weights[row * input + first + offset] = Float(tap / total)
            }
        }
        return weights
    }

    private static func cubic(_ x: Double) -> Double {
        let a = -0.5
        let x = abs(x)
        if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
        return 0
    }
}

// MARK: - Pixels

extension EmbeddingGemma2ImageProcessor {
    /// `[1, 3, H, W]` float32 pixels in 0...1 at the target size, and the soft-token count they make.
    /// Throws `invalidImage` for bytes ImageIO cannot decode or an empty frame.
    func pixels(from data: Data) throws -> (pixels: MLXArray, softTokens: Int) {
        let decoded = try Self.decode(data, longSide: Self.decodeLongSide)
        let plan = try resamplePlan(sourceHeight: decoded.height, sourceWidth: decoded.width)
        let bytes = MLXArray(decoded.rgba, [decoded.height, decoded.width, 4])
        var planes: [MLXArray] = []
        for channel in 0 ..< 3 {
            // 0...255 float, one channel at a time: Pillow's order (horizontal, round to 8 bits, vertical, round).
            var plane = bytes[0..., 0..., channel].asType(.float32)
            if plan.width != decoded.width {
                let columns = MLXArray(
                    Self.bicubicWeights(input: decoded.width, output: plan.width), [plan.width, decoded.width]
                )
                plane = round(clip(matmul(plane, columns.transposed()), min: 0, max: 255))
            }
            if plan.height != decoded.height {
                let rows = MLXArray(
                    Self.bicubicWeights(input: decoded.height, output: plan.height), [plan.height, decoded.height]
                )
                plane = round(clip(matmul(rows, plane), min: 0, max: 255))
            }
            plane = plane / 255
            eval(plane)
            planes.append(plane)
        }
        return (stacked(planes, axis: 0).expandedDimensions(axis: 0), plan.softTokens)
    }

    /// The most `bicubicWeights` floats one resampling pass may allocate (64 MB). A 10000×1 panorama would
    /// otherwise ask for a 13,440 × 10,000 matrix (537 MB); a 4032 → 912 pass is 3.7 M floats.
    static let maxWeightFloats = 16_000_000

    /// The target size and soft-token count for a decoded frame, or `unsupportedImageShape` when a resampling
    /// pass would exceed `maxWeightFloats` (an extreme aspect ratio): refused with a clear error, not allocated.
    func resamplePlan(sourceHeight: Int, sourceWidth: Int) throws -> (height: Int, width: Int, softTokens: Int) {
        let (height, width) = targetSize(height: sourceHeight, width: sourceWidth)
        guard width * sourceWidth <= Self.maxWeightFloats, height * sourceHeight <= Self.maxWeightFloats else {
            throw EmbeddingGemma2Error.unsupportedImageShape
        }
        return (height, width, softTokenCount(height: height, width: width))
    }

    /// The frame upright (EXIF orientation applied), in sRGB, as 8-bit RGBA over white, longest side capped.
    static func decode(_ data: Data, longSide: Int) throws -> (rgba: [UInt8], height: Int, width: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: longSide,
              ] as CFDictionary)
        else { throw EmbeddingGemma2Error.invalidImage }
        let (width, height) = (image.width, image.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw EmbeddingGemma2Error.invalidImage
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            // Opaque white underneath: a transparent PNG (a screenshot's corners) lands on white, not black.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw EmbeddingGemma2Error.invalidImage }
        return (rgba, height, width)
    }
}

// MARK: - Token layout

public enum EmbeddingGemma2ImagePath {
    /// The image path's version, kept in `MLXEmbeddingService.imageFingerprint`. It covers the token layout below
    /// (a prompt prefix, a title, a different marker) AND the preprocessing in `EmbeddingGemma2ImageProcessor`
    /// (decode, orientation, alpha matte, resample order, size arithmetic, rounding). ANY change to either
    /// bumps this string, which re-embeds every stored image vector. v1 was the layout alone (never shipped);
    /// v2 adds the Pillow-order resample and the single-resample decode.
    public static let promptVersion = "image-v2"

    /// `<bos> <boi> <image>×n <eoi> <eos>`: no text, no prefix (the model card: prefixes are for text only).
    static func tokens(
        softTokens: Int, vision: EmbeddingGemma2VisionConfiguration, beginOfSequence: Int, endOfSequence: Int
    ) -> [Int] {
        [beginOfSequence, vision.beginImageTokenID]
            + [Int](repeating: vision.imageTokenID, count: softTokens)
            + [vision.endImageTokenID, endOfSequence]
    }
}
