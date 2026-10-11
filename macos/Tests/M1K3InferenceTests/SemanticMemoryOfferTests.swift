//
//  SemanticMemoryOfferTests.swift
//  M1K3InferenceTests
//
//  When a brain download rides with "Also get semantic memory": only with Lil or Big, never for
//  Mini or pocket, never once the Mac is already on MLX embeddings or has the embedder on disk.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure decision; Kev's call: the
//  embedder is OFFERED WITH Lil/Big, pre-ticked; Mini-only users stay on Hashing). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — the reserved-slot decision, the size fallback (never "Zero KB") and the brain-named detail line. Confidence 0.85.

@testable import M1K3Inference
import Testing

struct SemanticMemoryOfferTests {
    @Test("Lil and Big downloads offer it while the Mac is on Hashing with nothing on disk")
    func offeredWithLilAndBig() {
        for tier in [BrainTier.lil, .big] {
            #expect(SemanticMemoryOffer.shouldOffer(brainTarget: tier, usingMLXEmbeddings: false, installed: false))
        }
    }

    @Test("Mini-only flows never see it: Mini, pocket and no brain at all")
    func neverForMiniOnly() {
        for tier in [BrainTier.mini, .pocket] {
            #expect(!SemanticMemoryOffer.shouldOffer(brainTarget: tier, usingMLXEmbeddings: false, installed: false))
        }
        #expect(!SemanticMemoryOffer.shouldOffer(brainTarget: nil, usingMLXEmbeddings: false, installed: false))
    }

    @Test("not offered once the Mac already uses MLX embeddings, or has the embedder on disk")
    func notWhenAlreadyHad() {
        #expect(!SemanticMemoryOffer.shouldOffer(brainTarget: .lil, usingMLXEmbeddings: true, installed: false))
        #expect(!SemanticMemoryOffer.shouldOffer(brainTarget: .lil, usingMLXEmbeddings: false, installed: true))
        #expect(!SemanticMemoryOffer.shouldOffer(brainTarget: .big, usingMLXEmbeddings: true, installed: true))
    }

    @Test("it is pre-ticked, and its toggle copy carries the size and the benefit")
    func preTickedWithCopy() {
        #expect(SemanticMemoryOffer.preTicked)
        let title = SemanticMemoryOffer.toggleTitle(size: "1.3 GB")
        #expect(title == "Also get semantic memory (1.3 GB)")
        #expect(SemanticMemoryOffer.toggleDetail == "Better recall of your notes.")
    }

    @Test("the size never reads Zero KB: an unpinned 0 falls back to the rough figure, marked with a ~")
    func sizeFallback() {
        let pinned = SemanticMemoryOffer.sizeText(catalogueBytes: 1_270_000_000)
        #expect(pinned == Int64(1_270_000_000).formatted(.byteCount(style: .file)))
        #expect(!pinned.hasPrefix("~"))
        let fallback = SemanticMemoryOffer.sizeText(catalogueBytes: 0)
        #expect(fallback == "~" + SemanticMemoryOffer.approximateBytes.formatted(.byteCount(style: .file)))
        #expect(!fallback.contains("Zero"))
    }

    @Test("O4: the toggle's slot is reserved before the first scan and shown after it, so the CTA never jumps")
    func slotIsReservedUntilScanned() {
        // Before the scan: reserved (invisible), for a Lil/Big download only.
        #expect(SemanticMemoryOffer.slot(brainTarget: .lil, scanned: false, usingMLXEmbeddings: false, installed: false) == .reserved)
        // After: shown if offered, gone if the Mac already holds the embedder.
        #expect(SemanticMemoryOffer.slot(brainTarget: .lil, scanned: true, usingMLXEmbeddings: false, installed: false) == .shown)
        #expect(SemanticMemoryOffer.slot(brainTarget: .lil, scanned: true, usingMLXEmbeddings: false, installed: true) == .none)
        // Never any slot for Mini-only flows.
        #expect(SemanticMemoryOffer.slot(brainTarget: .mini, scanned: false, usingMLXEmbeddings: false, installed: false) == .none)
        #expect(SemanticMemoryOffer.slot(brainTarget: nil, scanned: true, usingMLXEmbeddings: false, installed: false) == .none)
        // Already on MLX embeddings: nothing to reserve even before the scan.
        #expect(SemanticMemoryOffer.slot(brainTarget: .big, scanned: false, usingMLXEmbeddings: true, installed: false) == .none)
    }
}
