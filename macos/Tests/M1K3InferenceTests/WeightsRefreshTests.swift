//
//  WeightsRefreshTests.swift
//  M1K3InferenceTests
//
//  A brain's weights can change under it (Lil: mlx-community → Nace's Q4, planned 2026-11-18). Before this, the
//  new id read as "Lil not downloaded": the launch gate held Lil behind a 3 GB download and stranded the old
//  folder. These pin the pure half of the update path: which folder a tier loads, when an update is on offer, and
//  which folders the tier still claims.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-18, Confidence 0.85. Prior: none (new file).

import M1K3Inference
import Testing

struct WeightsRefreshTests {
    private let current = "nace-ai/Qwen3.5-4B-MLX"
    private let previous = "mlx-community/Qwen3.5-4B-MLX-4bit"

    private func resolve(complete: Set<String>, predecessor: String?? = .none) -> WeightsRefresh.Resolution {
        let previous: String? = predecessor ?? self.previous
        return WeightsRefresh.resolve(current: current, predecessor: previous, isComplete: { complete.contains($0) })
    }

    @Test("the current weights complete on disk load as they are: nothing to offer")
    func currentInstalled() {
        #expect(resolve(complete: [current, previous]) == .current(current))
        #expect(resolve(complete: [current, previous]).loadID == current)
        #expect(resolve(complete: [current]).updateTarget == nil)
    }

    @Test("only the previous weights on disk: they load now, and the update is offered, never fetched unasked")
    func predecessorInstalled() {
        let resolution = resolve(complete: [previous])
        #expect(resolution == .predecessor(previous, update: current))
        #expect(resolution.loadID == previous, "Lil keeps working from disk; no download gate")
        #expect(resolution.updateTarget == current)
        #expect(resolution.isOnDisk)
    }

    @Test("nothing complete on disk: the current weights are the download, as before")
    func nothingInstalled() {
        let resolution = resolve(complete: [])
        #expect(resolution == .download(current))
        #expect(resolution.loadID == current)
        #expect(!resolution.isOnDisk)
        #expect(resolution.updateTarget == nil, "a first download is not an update")
    }

    @Test("a torn update (complete is false) never wins over the working previous weights")
    func tornUpdateKeepsThePrevious() {
        // The caller's isComplete is the inventory's `.complete` state, not "a safetensors exists": an update
        // that died after the shard but before the tokenizer must not load (its heal re-downloads unasked).
        #expect(resolve(complete: [previous]).loadID == previous)
    }

    @Test("a tier with no predecessor behaves exactly as before")
    func noLineage() {
        #expect(resolve(complete: [current], predecessor: .some(nil)) == .current(current))
        #expect(resolve(complete: [previous], predecessor: .some(nil)) == .download(current))
    }

    @Test("the tier claims its predecessor only while it is the fallback that loads")
    func claimedIDs() {
        #expect(resolve(complete: [previous]).claimedIDs == [current, previous], "the update's partial is claimed too")
        #expect(resolve(complete: [current, previous]).claimedIDs == [current], "updated: the old folder is free")
        #expect(resolve(complete: []).claimedIDs == [current])
    }

    @Test("the update a brain offers: available while only the old weights are whole, ready while they still serve")
    func updateState() {
        func update(current: Bool, previous: Bool, serving: String?) -> WeightsUpdate? {
            WeightsRefresh.update(
                predecessor: self.previous, currentComplete: current, predecessorComplete: previous, servingID: serving
            )
        }
        #expect(update(current: false, previous: true, serving: previous) == .available)
        #expect(update(current: false, previous: true, serving: nil) == .available, "offered even while not loaded")
        #expect(update(current: true, previous: true, serving: previous) == .ready, "fetched: one tap switches")
        #expect(update(current: true, previous: true, serving: current) == nil, "switched: nothing left to offer")
        #expect(update(current: false, previous: false, serving: nil) == nil, "nothing on disk: a first download")
        #expect(WeightsRefresh.update(
            predecessor: nil, currentComplete: false, predecessorComplete: true, servingID: nil
        ) == nil, "no lineage, no update")
    }

    @Test("the old weights are left over only once the update is whole and they no longer serve")
    func leftover() {
        func leftover(current: Bool, previousOnDisk: Bool, serving: String?) -> String? {
            WeightsRefresh.leftover(
                predecessor: previous, predecessorOnDisk: previousOnDisk, currentComplete: current, servingID: serving
            )
        }
        #expect(leftover(current: true, previousOnDisk: true, serving: current) == previous)
        #expect(leftover(current: true, previousOnDisk: true, serving: nil) == previous, "another brain picked")
        #expect(leftover(current: true, previousOnDisk: true, serving: previous) == nil, "still serving: not yet")
        #expect(leftover(current: false, previousOnDisk: true, serving: nil) == nil, "the fallback: keep it")
        #expect(leftover(current: true, previousOnDisk: false, serving: current) == nil, "already gone")
    }

    @Test("every tier's lineage starts with its current id, holds at most one predecessor, never repeats")
    func lineageShape() {
        for tier in BrainTier.allCases {
            guard let id = tier.mlxModelID else {
                #expect(tier.lineageMLXModelIDs.isEmpty)
                continue
            }
            #expect(tier.lineageMLXModelIDs.first == id)
            #expect(tier.lineageMLXModelIDs.count <= 2, "one predecessor: each one is kept in step everywhere")
            #expect(Set(tier.lineageMLXModelIDs.map { $0.lowercased() }).count == tier.lineageMLXModelIDs.count)
        }
    }

    @Test("a lineage id is matched case-blind, the way the exact-id rules compare, and never by family")
    func lineageMembership() throws {
        let lil = try #require(BrainTier.lil.mlxModelID)
        #expect(BrainTier.lil.lineageContains(lil.uppercased()))
        #expect(!BrainTier.lil.lineageContains("lmstudio-community/Qwen3.5-4B-MLX-4bit"))
        #expect(BrainTier(lineageModelID: lil) == .lil)
        #expect(BrainTier(lineageModelID: "someone/else") == nil)
    }
}
