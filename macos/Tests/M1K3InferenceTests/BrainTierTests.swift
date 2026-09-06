//
//  BrainTierTests.swift
//  M1K3InferenceTests
//
//  Contract tests for the brain tiers — Mini / Lil / Big M1K3, the
//  "choose your brain" model selection echoed from the KMP app
//  (app/.../domain/ai/M1K3Tier.kt). Pure metadata + a RAM→tier recommendation
//  + a selection gate + a persistence round-trip, all Metal-free so they run
//  under `swift test`. The actual model download/generation is
//  verify-by-launch; THIS is the part we can pin.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-08, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-06-10 — four tiers (Gemma 4 era):
//  Lil → Qwen3.5-2B, Big → Gemma-4-E4B, new Huge gated to 32GB+.
//  Review: Kev + claude-opus-4-8, 2026-06-13 — Lil promoted Qwen3.5-2B → 4B:
//  the 2B-4bit ignored grounding and confabulated (greeted instead of answering,
//  invented facts on empty gate); 4B clears the reliability floor, same family
//  (xmlFunction tool-calls, pre-open-think) so it's a drop-in id swap.
//  Review: Kev + claude-fable-5, 2026-07-02 — Huge RETIRED (Qwen3-8B: weakest
//  tool-caller, nobody's favourite at anything; the all-gemma reshuffle).
//  Three tiers again; a persisted "huge" migrates to .big via
//  BrainTier(persisted:) — the Huge user is exactly who wants Big.
//  Review: Kev + claude-fable-5.1, 2026-09-06 — four tiers again — pocket (LFM2.5-1.2B as the non-AFM Mini): facts,
//  the measured 3.5 GB mobile floor, ordering, `offered(afm:)`, `recommended(…afm:)`, `easedToOfferedMini`.
//  Confidence 0.9.
//

@testable import M1K3Inference
import Testing

struct BrainTierTests {
    @Test("there are exactly four tiers, mini/pocket/lil/big — pocket is the Mini for devices without Apple Intelligence")
    func threeTiers() {
        #expect(BrainTier.allCases == [.mini, .pocket, .lil, .big])
    }

    @Test("every tier carries non-empty display copy")
    func copyIsPresent() {
        for tier in BrainTier.allCases {
            #expect(!tier.displayName.isEmpty)
            #expect(!tier.tagline.isEmpty)
            #expect(!tier.detail.isEmpty)
            #expect(!tier.glyph.isEmpty)
        }
    }

    @Test("Mini wears the Apple Intelligence symbol — it is Apple Intelligence")
    func miniGlyph() {
        #expect(BrainTier.mini.glyph == "apple.intelligence")
    }

    @Test("macOS keeps Lil's exact card copy — the platform-honesty byte freeze")
    func lilDetailMacOSBytesFrozen() {
        #if os(macOS)
            #expect(BrainTier.lil.detail.hasSuffix("Runs entirely on your machine."))
        #else
            #expect(!BrainTier.lil.detail.contains("Mac"))
        #endif
    }

    @Test("display names follow the M1K3 family naming")
    func displayNames() {
        #expect(BrainTier.mini.displayName == "Mini")
        #expect(BrainTier.lil.displayName == "Lil")
        #expect(BrainTier.big.displayName == "Big")
    }

    @Test("Mini runs on Apple Foundation Models with no download")
    func miniIsAppleNoDownload() {
        #expect(BrainTier.mini.backing == .appleFoundationModels)
        #expect(BrainTier.mini.approxDownloadMB == nil)
        #expect(!BrainTier.mini.requiresDownload)
    }

    @Test("the MLX tiers point at the dense Qwen3 / Gemma 4 models")
    func mlxTierModels() {
        // lil uses DENSE Qwen3 (not the Qwen3.5 GatedDeltaNet hybrid, which
        // CPU-spikes on mlx-swift-lm 3.31.3 — see MODEL_CHOICES.md). Dense routes
        // through the existing qwen3 path: .json tools, no pre-open-think,
        // quantized KV — verified against the real Qwen3 chat template.
        // lil is the NON-THINKING Instruct-2507 refresh since 2026-07-16: same
        // dense-qwen3 family/size, but no <think> phase — tools 4.4s vs 21.0s
        // median, reasoning answers 1.8s vs 11.9s, security parity with the
        // model it replaces (Run E, macos/scratch/eval-2026-07-15-model-runs/).
        // DWQ-2510 since 2026-09-05: the same weights under the DWQ quantization
        // recipe — 18/21 vs 15/21 on mains (security 6/7 vs 3/7; ×3 repeats
        // 16/21 vs 12/21), median turn 1774 ms vs 2011 ms (docs/evals/2026-09-05-lil-*).
        #expect(BrainTier.lil.mlxModelID == "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510")
        // big is gemma-4-12B since 2026-07-15: both June blockers cleared on the
        // pinned mlx-swift-lm 3.31.4 (vision_embedder sanitize IS in the tag;
        // the RotatingKVCache.temporalOrder tool-use crash did not reproduce),
        // and the live-path CHATEVAL swept 13/13 vs e4b's 9/13 — see
        // macos/scratch/eval-2026-07-15-model-runs/RESULTS.md + MODEL_CHOICES.md.
        #expect(BrainTier.big.mlxModelID == "mlx-community/gemma-4-12B-it-4bit")
        #expect(BrainTier.mini.mlxModelID == nil)
        for tier in [BrainTier.lil, .big] {
            #expect((tier.approxDownloadMB ?? 0) > 0)
            #expect(tier.requiresDownload)
        }
    }

    @Test("★ Lil is the recommended FRONT at every Mac size — Big is never auto-resident")
    func recommendationByMemory() {
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 8) == .mini)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 15.9) == .mini)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 16) == .lil)
        // ★ 2026-08-11, Kev's call on measured evidence: "lil is our snappy,
        // witty agent — and big is for deep reasoning." Big used to be the
        // automatic pick at 24GB+, which is why a 64GB Mac woke on the SLOW
        // brain. Same build, same fixtures, live path:
        //     lil 10,022ms median (max 18,132)
        //     big 30,500ms median (max 289,020)
        // Big is 3x slower with a tail that blew the 120s MCP deadline on an
        // ordinary question. It stays fully SELECTABLE (see the floors below) —
        // a user may still choose it — and it is reached for depth via
        // delegate_deep. It is simply never the automatic FRONT any more.
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 23.9) == .lil)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 24) == .lil)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 48) == .lil)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 64) == .lil)
    }

    @Test("Big stays SELECTABLE everywhere it can run — the change is the default, not the ladder")
    func bigRemainsSelectable() {
        // Dropping Big from the RECOMMENDATION must not drop it from the
        // product. A user who wants the deep brain resident can still pick it.
        #expect(BrainTier.big.isSelectable(forPhysicalMemoryGB: 16))
        #expect(BrainTier.big.isSelectable(forPhysicalMemoryGB: 64))
        #expect(!BrainTier.big.isSelectable(forPhysicalMemoryGB: 8))
    }

    @Test("★ deep reasoning has its OWN floor, independent of what is recommended")
    func deepReasoningFloor() {
        // Load-bearing separation. `capped`/`recommended` now top out at Lil, so
        // anything asking "can this Mac run Big?" via `capped` would get NO
        // forever — silently killing delegate_deep's escalation, the very
        // feature Big is being reserved for. Deep reasoning keeps the 24GB
        // comfortable bar it always had.
        #expect(!BrainTier.supportsDeepReasoning(forPhysicalMemoryGB: 16))
        #expect(!BrainTier.supportsDeepReasoning(forPhysicalMemoryGB: 23.9))
        #expect(BrainTier.supportsDeepReasoning(forPhysicalMemoryGB: 24))
        #expect(BrainTier.supportsDeepReasoning(forPhysicalMemoryGB: 64))
    }

    @Test("mobile recommendation is conservative — never Big, Lil only on iPad-Pro/Vision-Pro RAM")
    func recommendationOnMobile() {
        // Physical RAM OVERSTATES the per-app jetsam budget on iOS/visionOS, and
        // Big (gemma-4-12B, ~7.4GB at inference) exceeds any current mobile budget —
        // so the mobile ladder tops out at Lil and only on ≥16GB devices.
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 6, platform: .mobile) == .mini)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 8, platform: .mobile) == .mini)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 15.9, platform: .mobile) == .mini)
        // iPad Pro / Vision Pro (16GB+) comfortably run the 4-bit 4B Lil.
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 16, platform: .mobile) == .lil)
        // Big is NEVER recommended on mobile, even at high RAM.
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 24, platform: .mobile) == .lil)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 64, platform: .mobile) == .lil)
        // Both ladders now top out at Lil — but for DIFFERENT reasons, and the
        // distinction matters if either is ever retuned. Mobile: Big exceeds any
        // per-app jetsam budget, so it cannot run at all. Mac: Big runs fine and
        // is fully selectable, it is simply 3x slower than Lil (measured
        // 2026-08-11) and therefore the wrong DEFAULT.
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 24) == .lil)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 24, platform: .mac) == .lil)
    }

    @Test("tiers order by capability — mini < pocket < lil < big")
    func tierOrdering() {
        #expect(BrainTier.mini < .pocket)
        #expect(BrainTier.pocket < .lil)
        #expect(BrainTier.lil < .big)
        #expect(BrainTier.allCases.sorted() == [.mini, .pocket, .lil, .big])
        // min/max read naturally off the ordering (what `capped` relies on).
        #expect(min(BrainTier.big, .lil) == .lil)
        #expect(max(BrainTier.mini, .big) == .big)
    }

    @Test("capped eases a too-heavy automatic pick down to the Mac's comfortable ceiling")
    func cappedDemotesTooHeavy() {
        // Big auto-picked on a 16GB Mac → eased to that Mac's ceiling (Lil).
        #expect(BrainTier.capped(.big, forPhysicalMemoryGB: 16) == .lil)
        // Belt-and-braces with Big's 16GB selection floor (2026-07-15): even if
        // a persisted .big pick predates the floor, the cap eases an 8GB Mac to
        // Mini instead of letting it swap-thrash.
        #expect(BrainTier.capped(.big, forPhysicalMemoryGB: 8) == .mini)
    }

    @Test("capped NEVER raises a tier — a light pick on a big Mac stays put (no silent download)")
    func cappedNeverRaises() {
        // A .lil pick on a 64GB Mac is left alone: raising to Big would start
        // a multi-GB download the user never asked for (#81's honesty rule).
        #expect(BrainTier.capped(.lil, forPhysicalMemoryGB: 64) == .lil)
        #expect(BrainTier.capped(.mini, forPhysicalMemoryGB: 8) == .mini)
        #expect(BrainTier.capped(.mini, forPhysicalMemoryGB: 128) == .mini)
    }

    @Test("capped now eases Big down to Lil — the AUTOMATIC path picks snappy")
    func cappedEasesBigToLil() {
        // `capped` governs the AUTOMATIC path only (auto-route's "let M1K3
        // choose"). With Lil the recommendation everywhere, asking M1K3 to
        // choose gets you the snappy brain — which is the whole point of the
        // 2026-08-11 change. This USED to return .big at 24GB+.
        #expect(BrainTier.capped(.big, forPhysicalMemoryGB: 48) == .lil)
        #expect(BrainTier.capped(.big, forPhysicalMemoryGB: 24) == .lil)
        #expect(BrainTier.capped(.lil, forPhysicalMemoryGB: 16) == .lil)
    }

    @Test("★ a user who CHOSE Big keeps it across a relaunch — capping is not demotion")
    func explicitBigSurvivesRestore() {
        // The safety property that makes the ladder change tolerable, and the
        // one most likely to be broken by a careless follow-up. `capped` easing
        // Big to Lil is correct for the AUTOMATIC path and would be a betrayal
        // on the RESTORE path: someone who deliberately picked the deep brain
        // must not be silently downgraded every time they quit the app.
        // `selectableOrEased` only eases a pick below its tier's HARD floor.
        #expect(BrainTier.selectableOrEased(.big, forPhysicalMemoryGB: 64) == .big)
        #expect(BrainTier.selectableOrEased(.big, forPhysicalMemoryGB: 24) == .big)
        #expect(BrainTier.selectableOrEased(.big, forPhysicalMemoryGB: 16) == .big)
        // Below Big's 16GB hard floor it still eases — that pick can't run.
        #expect(BrainTier.selectableOrEased(.big, forPhysicalMemoryGB: 8) != .big)
    }

    @Test("Lil needs 8 GB on mobile — a 3 GB A12 iPad locks the card, a 12 GB iPhone 17 Pro passes (#227)")
    func lilMobileFloor() {
        // Kev's iPad (iPad11,6, 3 GB): picked Lil, iOS jetsam killed the load and
        // the relaunch re-entered the same brain — a crash loop. Lil is ~2.2 GB of
        // weights before KV; the per-app budget on a 3 GB device can never hold it.
        #expect(BrainTier.lil.minimumPhysicalMemoryGB(platform: .mobile) == 8)
        #expect(!BrainTier.lil.isSelectable(forPhysicalMemoryGB: 3, platform: .mobile))
        #expect(!BrainTier.lil.isSelectable(forPhysicalMemoryGB: 4, platform: .mobile))
        // 6 GB phones (iPhone 13 Pro / 14) are unmeasured — locked until a soak says otherwise.
        #expect(!BrainTier.lil.isSelectable(forPhysicalMemoryGB: 6, platform: .mobile))
        #expect(BrainTier.lil.isSelectable(forPhysicalMemoryGB: 8, platform: .mobile))
        #expect(BrainTier.lil.isSelectable(forPhysicalMemoryGB: 12, platform: .mobile))
        // Mini has no MLX footprint anywhere; the Mac ladder is untouched.
        #expect(BrainTier.mini.isSelectable(forPhysicalMemoryGB: 3, platform: .mobile))
        #expect(BrainTier.lil.minimumPhysicalMemoryGB(platform: .mac) == nil)
        #expect(BrainTier.lil.isSelectable(forPhysicalMemoryGB: 8, platform: .mac))
        // A persisted locked pick eases to a selectable tier on restore — the loop breaker.
        #expect(BrainTier.selectableOrEased(.lil, forPhysicalMemoryGB: 3, platform: .mobile) == .mini)
        #expect(BrainTier.selectableOrEased(.lil, forPhysicalMemoryGB: 12, platform: .mobile) == .lil)
    }

    @Test("Big is never selectable on mobile, whatever the RAM — a persisted Big eases down on restore")
    func bigNeverSelectableOnMobile() {
        for gigabytes in [8.0, 16, 64] {
            #expect(!BrainTier.big.isSelectable(forPhysicalMemoryGB: gigabytes, platform: .mobile))
        }
        // Eases to the mobile ladder's pick for that RAM: Mini under 16 GB, Lil at 16+.
        #expect(BrainTier.selectableOrEased(.big, forPhysicalMemoryGB: 8, platform: .mobile) == .mini)
        #expect(BrainTier.selectableOrEased(.big, forPhysicalMemoryGB: 16, platform: .mobile) == .lil)
        #expect(BrainTier.selectableOrEased(.big, forPhysicalMemoryGB: 64, platform: .mobile) == .lil)
        // The floor is infinite by design — callers must never format it through Int.
        #expect(BrainTier.big.minimumPhysicalMemoryGB(platform: .mobile) == .infinity)
        #expect(BrainTier.big.isSelectable(forPhysicalMemoryGB: 16, platform: .mac))
    }

    @Test("Big-12B carries the promised 16GB selection floor; Mini/Lil stay floorless (on the Mac)")
    func bigTwelveBSelectionFloor() {
        // The seam this test's predecessor kept warm ("gemma-4-12B will want it
        // back when Big upgrades") is now armed: 12B peaks ~7.4GB at inference
        // (2026-06-24 memloop, geometry unchanged), which an 8GB Mac physically
        // cannot hold — the card disables rather than letting an explicit pick
        // swap-thrash. 16GB is tight-but-runnable: selection stays permissive,
        // the RECOMMENDATION floor stays 24GB (recommendationByMemory above).
        #expect(BrainTier.big.minimumPhysicalMemoryGB == 16)
        #expect(!BrainTier.big.isSelectable(forPhysicalMemoryGB: 8))
        #expect(BrainTier.big.isSelectable(forPhysicalMemoryGB: 16))
        for tier in [BrainTier.mini, .lil] {
            #expect(tier.minimumPhysicalMemoryGB == nil)
            #expect(tier.isSelectable(forPhysicalMemoryGB: 8))
        }
    }

    @Test("a persisted pick below its tier's floor eases down; a selectable pick is never touched")
    func selectableOrEased() {
        // The 12B floor (2026-07-15) created a new boundary case: a persisted
        // .big on a sub-16GB Mac would render as a LOCKED row while still
        // running — stranded. Ease exactly that case through capped(); an
        // explicit pick that merely exceeds the RECOMMENDATION ceiling (Big on
        // a 16GB Mac) is legitimate and must never be demoted (#81's honesty
        // rule — capped() is for automatic picks only).
        #expect(BrainTier.selectableOrEased(.big, forPhysicalMemoryGB: 8) == .mini)
        #expect(BrainTier.selectableOrEased(.big, forPhysicalMemoryGB: 16) == .big)
        #expect(BrainTier.selectableOrEased(.big, forPhysicalMemoryGB: 64) == .big)
        #expect(BrainTier.selectableOrEased(.lil, forPhysicalMemoryGB: 8) == .lil)
        #expect(BrainTier.selectableOrEased(.mini, forPhysicalMemoryGB: 8) == .mini)
    }

    @Test("rawValue round-trips for @AppStorage persistence; retired 'huge' is not a live rawValue")
    func persistenceRoundTrip() {
        for tier in BrainTier.allCases {
            #expect(BrainTier(rawValue: tier.rawValue) == tier)
        }
        #expect(BrainTier(rawValue: "mini") == .mini)
        #expect(BrainTier(rawValue: "lil") == .lil)
        #expect(BrainTier(rawValue: "big") == .big)
        #expect(BrainTier(rawValue: "huge") == nil)
        #expect(BrainTier(rawValue: "nonsense") == nil)
    }

    @Test("persisted decoding migrates the retired 'huge' to Big — never a silent Mini downgrade")
    func persistedMigratesHugeToBig() {
        // A Huge user is exactly who wants Big (the biggest remaining brain).
        // Falling to nil at the read site would default them to Mini — hostile.
        #expect(BrainTier(persisted: "huge") == .big)
        // Live values decode unchanged.
        for tier in BrainTier.allCases {
            #expect(BrainTier(persisted: tier.rawValue) == tier)
        }
        // Junk still fails — the caller owns the default.
        #expect(BrainTier(persisted: "nonsense") == nil)
        #expect(BrainTier(persisted: "") == nil)
    }

    @Test("context-window metadata: big is the hard 8192 rotating window; dense-Qwen lil is wide")
    func contextWindowMetadata() {
        // big = gemma-4-12B → RotatingKVCache(maxSize: 8192): the load-bearing fact.
        #expect(BrainTier.big.approximateContextTokens == 8192)
        #expect(BrainTier.big.usesRotatingKVCache)
        // dense Qwen3 lil is unbounded (memory-bound, not truncation-bound) and wide.
        #expect(BrainTier.lil.approximateContextTokens == 32768)
        #expect(!BrainTier.lil.usesRotatingKVCache)
        // mini (AFM) is conservatively small and not rotating.
        #expect(BrainTier.mini.approximateContextTokens == 4096)
        #expect(!BrainTier.mini.usesRotatingKVCache)
        // Only big rotates — the clamp is a correctness bound there, a latency knob elsewhere.
        #expect(BrainTier.allCases.filter(\.usesRotatingKVCache) == [.big])
        // …but pocket's self-imposed 8k is a hard budget too: both get the history clamp.
        #expect(BrainTier.allCases.filter(\.hasClampedContext) == [.pocket, .big])
    }

    @Test("image input is a Big-only capability — gemma-4-12B through the VLM load path")
    func imageInputCapability() {
        // big = gemma-4-12B loaded via VLMModelFactory (vision tower resident,
        // proven on-device 2026-07-14/19) — the ONLY tier that can consume an
        // image today. The UI reads this to show/hide the attach affordance;
        // the mapping layer reads it to drop images before a non-vision model.
        #expect(BrainTier.big.supportsImageInput)
        // lil (dense Qwen3 text checkpoint) has no vision tower.
        #expect(!BrainTier.lil.supportsImageInput)
        // mini (AFM): Apple's bridge carries no image path in our
        // LanguageModel mirror yet — pinned OFF until that lands, so the UI
        // never offers an attach that would be silently dropped.
        #expect(!BrainTier.mini.supportsImageInput)
        #expect(BrainTier.allCases.filter(\.supportsImageInput) == [.big])
    }

    // MARK: - Pocket: the Mini for devices without Apple Intelligence (2026-09-06)

    @Test("pocket shows as Mini, runs LFM2.5-1.2B on MLX, one-time ~630 MB download")
    func pocketFacts() {
        #expect(BrainTier.pocket.displayName == "Mini")
        #expect(BrainTier.pocket.backing == .mlx(modelID: "mlx-community/LFM2.5-1.2B-Instruct-4bit"))
        #expect(BrainTier.pocket.mlxModelID == "mlx-community/LFM2.5-1.2B-Instruct-4bit")
        #expect(BrainTier.pocket.approxDownloadMB == 630)
        #expect(BrainTier.pocket.requiresDownload)
        #expect(BrainTier.pocket.prefersFastThinking)
        #expect(!BrainTier.pocket.supportsImageInput)
        #expect(!BrainTier.pocket.usesRotatingKVCache)
        #expect(BrainTier.pocket.approximateContextTokens == 8192)
        #expect(BrainTier.pocket.glyph != BrainTier.mini.glyph)
        #expect(BrainTier(persisted: "pocket") == .pocket)
    }

    @Test("pocket: no Mac floor; 3.5 GB on mobile — the 3 GB A12 iPad fails its first generation (measured)")
    func pocketFloors() {
        #expect(BrainTier.pocket.minimumPhysicalMemoryGB(platform: .mac) == nil)
        // 3.5 GB on mobile: the 3 GB A12 iPad (reports ~2.9) loads LFM2 and dies on
        // the first generation (Metal compiler LLVM error on the bf16 gather kernel).
        #expect(BrainTier.pocket.minimumPhysicalMemoryGB(platform: .mobile) == 3.5)
        #expect(!BrainTier.pocket.isSelectable(forPhysicalMemoryGB: 2.9, platform: .mobile))
        #expect(BrainTier.pocket.isSelectable(forPhysicalMemoryGB: 3.8, platform: .mobile))
    }

    @Test("pocket sits between mini and lil in the ladder")
    func pocketOrder() {
        #expect(BrainTier.mini < BrainTier.pocket)
        #expect(BrainTier.pocket < BrainTier.lil)
    }

    @Test("offered tiers: exactly one of mini/pocket per device — pocket replaces mini whenever AFM is blocked")
    func offered() {
        #expect(BrainTier.offered(afm: .available) == [.mini, .lil, .big])
        #expect(BrainTier.offered(afm: .notReady) == [.mini, .lil, .big])
        #expect(BrainTier.offered(afm: .blocked(userFixable: true)) == [.pocket, .lil, .big])
        #expect(BrainTier.offered(afm: .blocked(userFixable: false)) == [.pocket, .lil, .big])
    }

    @Test("the ladder recommends pocket where it would have recommended an unavailable Mini")
    func ladderWithoutAFM() {
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 8, platform: .mac, afm: .blocked(userFixable: false)) == .pocket)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 8, platform: .mac, afm: .available) == .mini)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 16, platform: .mac, afm: .blocked(userFixable: true)) == .lil)
        // The ladder names pocket even below its floor — MobileBrainMenu applies the floor.
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 2.9, platform: .mobile, afm: .blocked(userFixable: false)) == .pocket)
        #expect(BrainTier.recommended(forPhysicalMemoryGB: 6, platform: .mobile, afm: .notReady) == .mini)
    }

    @Test("a persisted Mini eases to whichever Mini this device can run — and back")
    func easedToOfferedMini() {
        // Blocked: the AFM Mini never answers here — pocket does.
        #expect(BrainTier.mini.easedToOfferedMini(afm: .blocked(userFixable: false)) == .pocket)
        #expect(BrainTier.mini.easedToOfferedMini(afm: .blocked(userFixable: true)) == .pocket)
        // Apple Intelligence back on: the instant Mini takes over (pocket is no longer offered).
        #expect(BrainTier.pocket.easedToOfferedMini(afm: .available) == .mini)
        // notReady is a transient sync: neither direction moves.
        #expect(BrainTier.mini.easedToOfferedMini(afm: .notReady) == .mini)
        #expect(BrainTier.pocket.easedToOfferedMini(afm: .notReady) == .pocket)
        // An explicit heavier pick is sovereign.
        #expect(BrainTier.lil.easedToOfferedMini(afm: .blocked(userFixable: false)) == .lil)
        #expect(BrainTier.big.easedToOfferedMini(afm: .available) == .big)
    }

    @Test("offered(afm:including:) keeps the serving tier visible through the notReady window")
    func offeredIncludingActive() {
        // Apple Intelligence just switched on, assets syncing, pocket still answering.
        #expect(BrainTier.offered(afm: .notReady, including: .pocket) == [.mini, .pocket, .lil, .big])
        // Already offered: unchanged.
        #expect(BrainTier.offered(afm: .available, including: .lil) == [.mini, .lil, .big])
        #expect(BrainTier.offered(afm: .blocked(userFixable: true), including: .pocket) == [.pocket, .lil, .big])
        // A stranded AFM Mini on a blocked device is never rescued — it cannot answer.
        #expect(BrainTier.offered(afm: .blocked(userFixable: false), including: .mini) == [.pocket, .lil, .big])
        #expect(BrainTier.offered(afm: .blocked(userFixable: true), including: .mini) == [.pocket, .lil, .big])
    }

    @Test("one download-size formatter for every shell: MB below a gigabyte, one decimal above")
    func downloadSizeLabel() {
        #expect(BrainTier.downloadSizeLabel(megabytes: 630) == "630 MB")
        #expect(BrainTier.downloadSizeLabel(megabytes: 2150) == "2.1 GB") // %.1f rounds half-even here
        #expect(BrainTier.downloadSizeLabel(megabytes: 1000) == "1.0 GB")
    }

    @Test("a pocket below its floor eases to Mini (unready → the shell's Home-only path), never to itself")
    func pocketBelowFloorEasesToMiniNotItself() {
        // The 3 GB A12 iPad, Apple Intelligence blocked: easedToOfferedMini says pocket,
        // the floor says no — the landing is Mini, and the shell reads hasLocalBrain == false.
        let eased = BrainTier.selectableOrEased(.pocket, forPhysicalMemoryGB: 2.9, platform: .mobile)
        #expect(eased == .mini)
        #expect(!BrainTier.pocket.isSelectable(forPhysicalMemoryGB: 2.9, platform: .mobile))
        // Above the floor it stays.
        #expect(BrainTier.selectableOrEased(.pocket, forPhysicalMemoryGB: 3.8, platform: .mobile) == .pocket)
    }
}
