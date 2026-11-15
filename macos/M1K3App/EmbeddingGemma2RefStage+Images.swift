//
//  EmbeddingGemma2RefStage+Images.swift
//  M1K3App
//
//  The image half of the EmbeddingGemma 2 reference stage (#836). After the text cases, each generated
//  drawing in the fixture goes through `MLXEmbeddingService.embedImage` — the lazily loaded vision tower — and
//  its vector must match mlx-vlm's at ≥ 0.999 cosine at 768 and at the MRL-512 width the store uses. Then the
//  text → image relevance order must hold with OUR vectors, and the stage MEASURES (never decides) the numbers a
//  per-modality floor would be read from: the text↔image cosine distribution against text↔text, whether mixing
//  image vectors into a text search crowds out the relevant text hit, and what the text floors would have let
//  through. Also reported: RAM and time for one image, and that dropping the tower frees its memory and the next
//  image reloads it. Nothing here signs a floor.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.75. Prior: none (new file; #836).

import Foundation
import M1K3Knowledge
import M1K3MLX

extension EmbeddingGemma2RefStage {
    struct ImageResult {
        let cos768: Float
        let cos512: Float
        let vector768: [Float]
        let vector512: [Float]
        let millis: Double
    }

    static func runImages(
        reference: Reference, service: MLXEmbeddingService, results: [String: CaseResult],
        emit: @escaping (String) -> Void
    ) async {
        guard let images = reference.images, !images.isEmpty else { return }
        emit("• eg2ref images: \(images.count) generated drawings; the vision tower loads on the first")
        emit("eg2ref image fingerprint: \(service.imageFingerprint ?? "nil") (text: \(service.fingerprint))")
        let clock = ContinuousClock()
        do {
            // The peak counter restarts here, so `peak=` below is the images' own (the text load's 1.2 GB read is not).
            MLXMemoryBudget.resetPeak()
            emit("eg2ref memory before any image: \(memorySnapshot())")
            var outcomes: [String: ImageResult] = [:]
            var coldMillis = 0.0
            for (index, image) in images.enumerated() {
                guard let data = Data(base64Encoded: image.pngBase64) else {
                    emit("✗ eg2ref images: \(image.id) has no PNG bytes")
                    return
                }
                let start = clock.now
                let v768 = try await service.embedImage(data)
                let millis = seconds(clock.now - start) * 1000
                if index == 0 { coldMillis = millis }
                let v512 = try MatryoshkaTruncation.truncateValidated(v768, to: storeWidth)
                let outcome = ImageResult(
                    cos768: VectorMath.cosineSimilarity(v768, image.embedding768),
                    cos512: VectorMath.cosineSimilarity(v512, image.embedding512),
                    vector768: v768, vector512: v512, millis: millis
                )
                outcomes[image.id] = outcome
                emit(String(
                    format: "eg2ref image %@ cos768 %.5f cos512 %.5f %.0f ms%@", image.id, outcome.cos768,
                    outcome.cos512, millis, index == 0 ? " (cold: includes loading the vision tower)" : ""
                ))
                if index == 0 { emit("eg2ref memory after the first image: \(memorySnapshot())") }
            }
            emit("eg2ref memory after all images: \(memorySnapshot())")
            let warm = outcomes.values.map(\.millis).sorted()
            let warmMedian = warm.isEmpty ? 0 : warm[warm.count / 2]

            // Rank with our vectors: text query cases come from the text results, images from `outcomes`.
            var combined = results
            for (id, outcome) in outcomes {
                combined[id] = CaseResult(
                    tokensOK: true, cos768: outcome.cos768, cos512: outcome.cos512, pipeline: outcome.cos512,
                    vector768: outcome.vector768, vector512: outcome.vector512, embedMillis: outcome.millis
                )
            }
            let rankingOK = rank(reference.imageRankingChecks ?? [], results: combined, emit: emit)
            let top1 = topOne(images: images, results: results, outcomes: outcomes)
            emit("eg2ref images top-1: \(top1.hits)/\(images.count) queries find their own picture among all \(images.count) (reference: all)")

            measureFloors(reference: reference, images: images, results: results, outcomes: outcomes, emit: emit)
            await measureUnload(service: service, images: images, emit: emit, clock: clock)

            let minCos768 = outcomes.values.map(\.cos768).min() ?? 0
            let minCos512 = outcomes.values.map(\.cos512).min() ?? 0
            let finite = outcomes.values.allSatisfy { $0.cos768.isFinite && $0.cos512.isFinite }
            let pass = outcomes.count == images.count && finite && minCos768 >= threshold
                && minCos512 >= threshold && rankingOK && top1.hits == images.count
            emit(String(
                format: "eg2ref images summary: %d/%d · min cos768 %.5f · min cos512 %.5f · ranking %@ · top-1 %d/%d · "
                    + "cold %.0f ms · warm median %.0f ms · process peak RSS %d MB · %@",
                outcomes.count, images.count, minCos768, minCos512, rankingOK ? "ok" : "WRONG", top1.hits,
                images.count, coldMillis, warmMedian, peakRSSMB(), pass ? "PASS" : "FAIL"
            ))
        } catch {
            emit("✗ eg2ref images: \(error)")
        }
    }

    // MARK: Retrieval

    private static func topOne(
        images: [Reference.ImageCase], results: [String: CaseResult], outcomes: [String: ImageResult]
    ) -> (hits: Int, misses: [String]) {
        var misses: [String] = []
        for image in images {
            guard let query = results[image.queryCase]?.vector512 else { misses.append(image.id); continue }
            let best = images.max {
                VectorMath.cosineSimilarity(query, outcomes[$0.id]?.vector512 ?? [])
                    < VectorMath.cosineSimilarity(query, outcomes[$1.id]?.vector512 ?? [])
            }
            if best?.id != image.id { misses.append(image.id) }
        }
        return (images.count - misses.count, misses)
    }

    private struct Spread {
        let values: [Float]

        var description: String {
            guard !values.isEmpty else { return "n=0" }
            let sorted = values.sorted()
            let mean = sorted.reduce(0, +) / Float(sorted.count)
            return String(
                format: "n=%d min %.3f p10 %.3f median %.3f mean %.3f p90 %.3f max %.3f", sorted.count, sorted[0],
                sorted[sorted.count / 10], sorted[sorted.count / 2], mean, sorted[sorted.count * 9 / 10],
                sorted[sorted.count - 1]
            )
        }
    }

    /// The floor inputs, as measurements only: matching vs non-matching cosines per modality pair, the crowd-out
    /// check, and what the text floors would admit. Every vector is at the stored 512 width.
    private static func measureFloors(
        reference: Reference, images: [Reference.ImageCase], results: [String: CaseResult],
        outcomes: [String: ImageResult], emit: (String) -> Void
    ) {
        func cosine(_ a: [Float], _ b: [Float]) -> Float {
            VectorMath.cosineSimilarity(a, b)
        }
        var queryOwn: [Float] = [], queryOther: [Float] = [], captionOwn: [Float] = [], captionOther: [Float] = []
        var textOwn: [Float] = [], textOther: [Float] = [], imageImage: [Float] = []
        for image in images {
            guard let query = results[image.queryCase]?.vector512, let caption = results[image.captionCase]?.vector512,
                  let own = outcomes[image.id]?.vector512
            else { continue }
            for other in images {
                guard let otherImage = outcomes[other.id]?.vector512,
                      let otherCaption = results[other.captionCase]?.vector512
                else { continue }
                let isOwn = other.id == image.id
                if isOwn {
                    queryOwn.append(cosine(query, otherImage))
                    captionOwn.append(cosine(caption, otherImage))
                    textOwn.append(cosine(query, otherCaption))
                } else {
                    queryOther.append(cosine(query, otherImage))
                    captionOther.append(cosine(caption, otherImage))
                    textOther.append(cosine(query, otherCaption))
                    if image.id < other.id { imageImage.append(cosine(own, otherImage)) }
                }
            }
        }
        emit("eg2ref floors [text query → its picture]    \(Spread(values: queryOwn).description)")
        emit("eg2ref floors [text query → other pictures]  \(Spread(values: queryOther).description)")
        emit("eg2ref floors [caption doc → its picture]    \(Spread(values: captionOwn).description)")
        emit("eg2ref floors [caption doc → other pictures] \(Spread(values: captionOther).description)")
        emit("eg2ref floors [text query → its caption]     \(Spread(values: textOwn).description)  (text↔text, for scale)")
        emit("eg2ref floors [text query → other captions]  \(Spread(values: textOther).description)")
        emit("eg2ref floors [picture ↔ other picture]     \(Spread(values: imageImage).description)")
        let gap = (queryOwn.min() ?? 0) - (queryOther.max() ?? 0)
        emit(String(
            format: "eg2ref floors text→image: weakest match %.3f, strongest non-match %.3f, gap %.3f",
            queryOwn.min() ?? 0, queryOther.max() ?? 0, gap
        ))

        measureCrowding(reference: reference, images: images, results: results, outcomes: outcomes, emit: emit)
    }

    /// Mixing image vectors into a text search: for every text query with a known relevant text document, how
    /// many image vectors outrank it, and how many images clear the TEXT floors (memory 0.67, chunk 0.70).
    private static func measureCrowding(
        reference: Reference, images: [Reference.ImageCase], results: [String: CaseResult],
        outcomes: [String: ImageResult], emit: (String) -> Void
    ) {
        let floors = EmbedderFloors.embeddingGemma2
        // query case → the text document that is its answer: the fixture's ranking pairs plus each image's caption.
        var answers: [String: String] = [:]
        for check in reference.rankingChecks {
            answers[check.query] = check.relevant
        }
        for image in images {
            answers[image.queryCase] = image.captionCase
        }
        let textDocuments = reference.cases.filter { $0.role == "document" }.map(\.id)
        let imageVectors = images.compactMap { outcomes[$0.id]?.vector512 }
        var displacedTop1 = 0, displacedTop3 = 0, evaluated = 0, imagesAboveRelevant = 0
        var imagesAboveMemoryFloor = 0, imagesAboveChunkFloor = 0, queryCount = 0
        var strongestImageGap: Float = 1
        for (queryID, answerID) in answers.sorted(by: { $0.key < $1.key }) {
            guard let query = results[queryID]?.vector512, let relevant = results[answerID]?.vector512 else { continue }
            let relevantScore = VectorMath.cosineSimilarity(query, relevant)
            let textScores = textDocuments.compactMap { id in results[id].map { VectorMath.cosineSimilarity(query, $0.vector512) } }
            let imageScores = imageVectors.map { VectorMath.cosineSimilarity(query, $0) }
            let textRank = textScores.filter { $0 > relevantScore }.count
            let above = imageScores.filter { $0 > relevantScore }.count
            evaluated += 1
            imagesAboveRelevant += above
            if textRank == 0, textRank + above > 0 { displacedTop1 += 1 }
            if textRank < 3, textRank + above >= 3 { displacedTop3 += 1 }
            strongestImageGap = min(strongestImageGap, relevantScore - (imageScores.max() ?? 0))
            // Images at or past the text floors for this query, counting the query's OWN picture separately.
            queryCount += 1
            imagesAboveMemoryFloor += imageScores.filter { $0 >= floors.memory }.count
            imagesAboveChunkFloor += imageScores.filter { $0 >= floors.chunk }.count
        }
        emit(
            "eg2ref crowding: \(evaluated) text queries with a relevant text doc, searched over \(textDocuments.count) "
                + "text docs + \(imageVectors.count) image vectors: relevant doc pushed out of rank 1 by an image "
                + "\(displacedTop1)×, out of the top 3 \(displacedTop3)×, images above the relevant doc \(imagesAboveRelevant) total"
        )
        emit(String(
            format: "eg2ref crowding: tightest margin (relevant text doc − best image) %.3f", strongestImageGap
        ))
        emit(String(
            format: "eg2ref crowding: image vectors clearing the TEXT floors across %d queries: memory %.2f → %d, chunk %.2f → %d "
                + "(each query has at most one picture that belongs)",
            queryCount, floors.memory, imagesAboveMemoryFloor, floors.chunk, imagesAboveChunkFloor
        ))
    }

    // MARK: Memory

    /// Drops the tower, reports the footprint, embeds one more image (a reload), and reports again.
    private static func measureUnload(
        service: MLXEmbeddingService, images: [Reference.ImageCase], emit: (String) -> Void, clock: ContinuousClock
    ) async {
        guard let image = images.first, let data = Data(base64Encoded: image.pngBase64) else { return }
        let before = footprintMB()
        await service.unloadVision()
        let after = footprintMB()
        emit("eg2ref unload: footprint \(before) MB → \(after) MB after dropping the vision tower; \(memorySnapshot())")
        do {
            let start = clock.now
            _ = try await service.embedImage(data)
            emit(String(
                format: "eg2ref reload: one image after the drop took %.0f ms; %@",
                seconds(clock.now - start) * 1000, memorySnapshot()
            ))
        } catch {
            emit("✗ eg2ref reload: \(error)")
        }
    }

    static func memorySnapshot() -> String {
        "\(MLXMemoryBudget.snapshotDescription(label: "mlx")) · footprint \(footprintMB()) MB"
    }

    /// The process's physical footprint (what Activity Monitor's Memory column shows), in whole MB.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) / 1_048_576 : -1
    }
}
