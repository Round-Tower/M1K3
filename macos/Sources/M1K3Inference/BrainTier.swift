//
//  BrainTier.swift
//  M1K3Inference
//
//  The three brains the user chooses between at onboarding — Mini / Lil / Big
//  M1K3 — echoing the KMP app's tier concept (app/.../domain/ai/M1K3Tier.kt).
//  Mini is Apple Foundation Models (instant, on-device, no download); Lil and
//  Big are local MLX models that download once. Pure value type in the seam
//  module (no MLX import), so its metadata + the device recommendation + the
//  selection gate + persistence are `swift test`-able; AppEnvironment maps
//  `.backing` to a concrete provider.
//
//  Model mapping (2026-06-13, mlx-swift-lm 3.31.3): Lil = Qwen3.5-4B,
//  Big = Gemma-4-E4B (the gemma-3n-E4B successor). Huge = Qwen3.5-9B — the
//  intended gemma-4-12B uses a `gemma4_unified` arch that 3.31.3 cannot load
//  (probe-verified, Gate B); swap the id once upstream registers it.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-08, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-06-10 — Gemma 4 era: four tiers, new
//  RAM thresholds (Big is ~7GB at inference now → recommended floor 24GB),
//  Huge selectable at 32GB+, recommended at 48GB+.
//  Review: Kev + claude-opus-4-8, 2026-06-13 — Lil 2B → 4B. The 2B-4bit was
//  below the floor for grounded generation + tool use (ignored good sources,
//  confabulated on an empty gate); 4B is the same Qwen3.5 family so tool-call
//  format (xmlFunction) + pre-open-think resolve unchanged. ~3GB, still fits 16GB.
//  Review: Kev + claude-opus-4-8, 2026-06-30 — added approximateContextTokens +
//  usesRotatingKVCache (the long-context work). big=8192 is the HARD gemma-4
//  RotatingKVCache window (past it the persona/grounding head silently rotates
//  out); lil/huge=32768 unbounded KVCacheSimple. HistoryBudgetPolicy clamps the
//  conversation replay below the rotating window. Token counts are estimates —
//  on-device SelfTest verify-owed (the [SPIKE]); the gemma cliff is code-grounded.
//  Review: Kev + claude-opus-4-8, 2026-06-22 — Lil/Huge moved OFF Qwen3.5 to
//  DENSE Qwen3 (Qwen3-4B-4bit / Qwen3-8B-4bit). Qwen3.5 is a GatedDeltaNet
//  hybrid whose per-timestep recurrent scan CPU-spikes on mlx-swift-lm 3.31.3.
//  NOTE: the Qwen3.5 mapping/claims ABOVE are now historical — dense Qwen3 routes
//  to .json tools (NOT xmlFunction) and does NOT pre-open <think> (verified vs the
//  real Qwen3 template); quantized KV stays safe (attentionWithCacheUpdate path).
//  See macos/docs/MODEL_CHOICES.md.
//  Review: Kev + claude-fable-5, 2026-07-02 — HUGE RETIRED (the all-gemma
//  Review: Kev + claude-fable-5.1, 2026-09-05 — platform-aware selection floor: Lil is 8 GB on
//  .mobile (a 3 GB A12 iPad crash-looped on it, #227); every Mac accessor unchanged.
//  reshuffle, step 1). Qwen3-8B was the weakest tool-caller and nobody's
//  favourite at anything; gemma-4 native tool-calling is Kev-verified live on
//  3.31.4. Three tiers again. A persisted "huge" migrates to .big via
//  `init(persisted:)` — never a silent Mini downgrade. The memory-floor /
//  isSelectable seam is KEPT (returns nil today): gemma-4-12B takes the Big
//  slot with a floor once upstream fixes RotatingKVCache.temporalOrder.
//

import Foundation

/// How a brain actually runs.
public enum BrainBacking: Sendable, Equatable {
    /// Apple's built-in on-device model — instant, no download.
    case appleFoundationModels
    /// A local MLX model identified by its HuggingFace id (downloads on first use).
    case mlx(modelID: String)
}

/// One of the three M1K3 brains. `rawValue` ("mini"/"lil"/"big") is the
/// stable persistence key — decode stored values through `init(persisted:)`,
/// which also migrates the retired "huge" (2026-07-02) to `.big`.
public enum BrainTier: String, CaseIterable, Identifiable, Sendable, Comparable {
    case mini
    case lil
    case big

    public var id: String {
        rawValue
    }

    /// Decode a persisted tier string, migrating retired tiers instead of
    /// failing: "huge" (retired 2026-07-02, was Qwen3-8B) → `.big` — the Huge
    /// user is exactly who wants the biggest remaining brain, and a nil at the
    /// read site would silently default them to Mini. Junk still returns nil;
    /// the caller owns the default.
    public init?(persisted raw: String) {
        if raw == "huge" {
            self = .big
            return
        }
        self.init(rawValue: raw)
    }

    /// Capability/resource ordering: mini < lil < big. Explicit (NOT the
    /// `allCases` declaration order) so a future reorder can't silently change it.
    /// Drives `capped` and any "is this a heavier brain?" comparison.
    private var weight: Int {
        switch self {
        case .mini: 0
        case .lil: 1
        case .big: 2
        }
    }

    public static func < (lhs: BrainTier, rhs: BrainTier) -> Bool {
        lhs.weight < rhs.weight
    }

    public var displayName: String {
        switch self {
        case .mini: "Mini"
        case .lil: "Lil"
        case .big: "Big"
        }
    }

    /// Speed-first tiers: in auto thinking-mode they don't burn a `<think>` phase
    /// on a plain grounded lookup (only on genuinely analytic or long asks), where
    /// the heavier tiers keep the grounded ⇒ think default. Mini is Apple Foundation
    /// Models (no think toggle), so the flag is a harmless no-op there; Lil is the
    /// MLX speed tier this actually accelerates.
    public var prefersFastThinking: Bool {
        self == .mini || self == .lil
    }

    /// How the heartbeat digest explains the tier in apposition — "Running on
    /// Big, the larger brain." A bare proper noun in a bare-generate prompt
    /// reads as a housemate (three live pulses kept Big company on the shelf,
    /// 2026-08-30).
    public var heartbeatDescriptor: String {
        switch self {
        case .mini: "the built-in brain"
        case .lil: "the smaller brain"
        case .big: "the larger brain"
        }
    }

    /// The one-line personality hook (lifted from the KMP tiers).
    public var tagline: String {
        switch self {
        case .mini: "Fast and focused"
        case .lil: "Sharp and capable"
        case .big: "Full intelligence"
        }
    }

    /// The longer capability description shown on the brain card.
    public var detail: String {
        switch self {
        case .mini:
            "Apple's built-in on-device model. "
                + "No download. The quickest way to start."
        case .lil:
            Self.lilDetail
        case .big:
            "Maximum capability, fully local. The full M1K3."
        }
    }

    /// Platform-honest wording: the same card renders in the iOS/visionOS shell,
    /// where "your Mac" would be a lie on an iPhone (caught on-simulator,
    /// 2026-07-18; consolidated onto HostPlatform same-day — macOS bytes frozen,
    /// pinned in BrainTierTests).
    private static var lilDetail: String {
        "A fully local engine — multi-turn conversation, memory, and "
            + "reasoning that keeps up with you. Runs entirely on \(HostPlatform.yourDevice)."
    }

    /// SF Symbol for the brain card. Speed → power, echoing the KMP emojis
    /// (🤏 / ⚡ / 🧠).
    public var glyph: String {
        switch self {
        case .mini: "hare.fill"
        case .lil: "bolt.fill"
        case .big: "brain.head.profile.fill"
        }
    }

    public var backing: BrainBacking {
        switch self {
        case .mini: .appleFoundationModels
        // DENSE Qwen3, the NON-THINKING Instruct-2507 refresh since 2026-07-16
        // (was bare Qwen3-4B-4bit): same family/size/arch — .json tools,
        // quantized KV, no pre-open-think — but no <think> phase at all, which
        // is where the speed lives: tools 4.4s vs 21.0s median, reasoning
        // answers 1.8s vs 11.9s, security parity with the model it replaces
        // (Run E, 44 fixtures, macos/docs/MODEL_CHOICES.md 2026-07-16 entry).
        // The thinking TOGGLE is pinned off for the 2507 line in MLXGemmaProvider
        // (its template has no enable_thinking — the reasoning picker hides).
        // DWQ-2510 since 2026-09-05: identical weights, the distilled-weight-
        // quantization recipe; A/B on mains 18/21 vs 15/21, security 6/7 vs 3/7
        // (docs/evals/2026-09-05-lil-*.json, published at m1k3.app/brains).
        case .lil: .mlx(modelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510")
        // gemma-4-12B since 2026-07-15 (was e4b): both June blockers cleared on
        // the pinned mlx-swift-lm 3.31.4 — the vision_embedder sanitize fix IS
        // in the tag, and the RotatingKVCache.temporalOrder tool-use crash did
        // not reproduce (full tool arm, exit 0). Live-path CHATEVAL: 13/13 vs
        // e4b's 9/13 (incl. a 17-min code-gen melt), reasoning 6/6 vs 3/6,
        // prompt-leak 7/7 vs 4/7. Cost: ~2.6× slower tool turns. See
        // docs/MODEL_CHOICES.md (2026-07-15 entry) for the full matrix.
        case .big: .mlx(modelID: "mlx-community/gemma-4-12B-it-4bit")
        }
    }

    /// The HuggingFace model id for an MLX-backed tier, or `nil` for Mini (Apple).
    public var mlxModelID: String? {
        if case let .mlx(modelID) = backing { return modelID }
        return nil
    }

    /// Approx one-time download in MB, or `nil` for the no-download Apple tier.
    /// Rough estimates surfaced as "~NN MB"; the real size shows on the progress
    /// bar at download time. lil is Qwen3-4B-Instruct-2507 (on-disk 2026-07-16 —
    /// existing Lil users pay one ~2.1GB re-download after the swap); big is
    /// gemma-4-12B (HF index, 2026-07-15 — same one-time ~6.7GB re-download
    /// story; the model gate's progress bar is the honest surface for both).
    public var approxDownloadMB: Int? {
        switch self {
        case .mini: nil
        case .lil: 2150
        case .big: 6740
        }
    }

    public var requiresDownload: Bool {
        approxDownloadMB != nil
    }

    /// Approximate USABLE context window in tokens — a per-tier FACT, not a knob,
    /// used by `HistoryBudgetPolicy` to size the conversation replay. It is the
    /// budget layer's hard upper bound, especially on a rotating-KV tier.
    /// - `mini` (Apple Foundation Models): a conservative ~4K until measured —
    ///   AFM manages its own window and overflows are surfaced as errors, so
    ///   under-estimating is the safe direction.
    /// - `lil` (dense Qwen3, `maxKVSize == nil` → `KVCacheSimple`): the
    ///   native ~32K window; growth is MEMORY-bounded, never silently truncated.
    /// - `big` (gemma-4-12B, `RotatingKVCache(maxSize: 8192)`): a HARD 8192-token
    ///   sliding window — past it the head (persona + grounding) rotates OUT
    ///   during prefill with no error. Same cache geometry as the e4b it
    ///   replaced (gemma-4 family stays off the quantized-KV allow-list).
    ///   See `usesRotatingKVCache`.
    public var approximateContextTokens: Int {
        switch self {
        case .mini: 4096
        case .lil: 32768
        case .big: 8192
        }
    }

    /// Whether this tier can consume an attached image. Only Big today:
    /// gemma-4-12B loads through VLMModelFactory with its vision tower
    /// resident (proven on-device 2026-07-14/19, ~zero RAM delta vs the
    /// text-only load). The UI reads this to show/hide the attach affordance;
    /// the provider-side mapping drops images (loudly) for any tier where
    /// this is false. Mini stays off until the AFM bridge carries an image
    /// path; lil is a text-only checkpoint.
    public var supportsImageInput: Bool {
        self == .big
    }

    /// True when the backing model uses a fixed sliding-window KV cache
    /// (`RotatingKVCache`): exceeding `approximateContextTokens` silently drops the
    /// prompt HEAD rather than erroring, so the budget layer must clamp BELOW it
    /// (with margin for the char≈token estimate). Only `big` (gemma-4-12B) today;
    /// the dense-Qwen lil uses an unbounded `KVCacheSimple`. Verified against
    /// `MLXGemmaProvider`'s per-family cache config (see docs/MODEL_CHOICES.md).
    public var usesRotatingKVCache: Bool {
        self == .big
    }

    /// The memory floor below which this brain shouldn't even be SELECTABLE
    /// (the card disables with a "needs NN GB" badge), or nil for no gate.
    /// Distinct from `recommended` — selection is permissive, recommendation
    /// is comfortable. The seam kept warm since Huge retired (2026-07-02) is
    /// armed again for 12B-Big (2026-07-15): ~7.4GB peak at inference is
    /// physically impossible on an 8GB Mac, so an explicit pick there would
    /// only swap-thrash. 16GB is tight-but-runnable; the RECOMMENDATION floor
    /// stays 24GB.
    public var minimumPhysicalMemoryGB: Double? {
        minimumPhysicalMemoryGB(platform: .mac)
    }

    /// The same floor, per platform. On iOS/iPadOS the per-app jetsam budget is
    /// well under physical RAM: Lil's ~2.2 GB of weights (plus KV) cannot load on
    /// a 3 GB A12 iPad — the load is killed and a relaunch into the persisted pick
    /// loops (#227, Kev's iPad, 2026-09-05). 8 GB = the iPhone 15 Pro-class and
    /// later, the only cohort with any evidence behind it; 6 GB phones are
    /// unmeasured and stay locked until a soak says otherwise (loosen here + the
    /// test). Big is never offered on mobile.
    public func minimumPhysicalMemoryGB(platform: DevicePlatform) -> Double? {
        switch (self, platform) {
        case (.mini, _): nil
        case (.lil, .mac): nil
        case (.lil, .mobile): 8
        case (.big, _): 16
        }
    }

    /// Whether this Mac has enough memory to offer the tier at all.
    public func isSelectable(forPhysicalMemoryGB gigabytes: Double) -> Bool {
        isSelectable(forPhysicalMemoryGB: gigabytes, platform: .mac)
    }

    /// Whether this device has enough memory to offer the tier at all.
    public func isSelectable(forPhysicalMemoryGB gigabytes: Double, platform: DevicePlatform) -> Bool {
        guard let floor = minimumPhysicalMemoryGB(platform: platform) else { return true }
        return gigabytes >= floor
    }

    /// RAM at which running Big is COMFORTABLE — the bar for reaching the deep
    /// tier on demand (delegate_deep), as opposed to running it as the resident
    /// front. Deliberately NOT derived from `recommended`/`capped`: those now
    /// top out at Lil, so `capped(.big, …) == .big` is false everywhere and any
    /// caller asking "can this Mac run Big?" through them would get NO forever,
    /// silently disabling escalation — the one job Big is being kept for.
    ///
    /// 24GB is the same comfortable bar Big's recommendation used to carry; the
    /// number didn't change, only what it governs.
    public static let deepReasoningFloorGB: Double = 24

    /// Whether this Mac can comfortably host Big for a deep dive.
    public static func supportsDeepReasoning(forPhysicalMemoryGB gigabytes: Double) -> Bool {
        gigabytes >= deepReasoningFloorGB
    }

    /// The brain best matched to this Mac's memory, echoing KMP's device tiers.
    /// Big (gemma-4-12B) peaks ~7.4GB at inference — recommending it on a
    /// 16GB Mac that also runs a browser would be hostile, so its floor
    /// is 24GB. Big is the ceiling for every larger Mac (Huge retired
    /// 2026-07-02). Tunable thresholds.
    public static func recommended(
        forPhysicalMemoryGB gigabytes: Double,
        platform: DevicePlatform = .mac
    ) -> BrainTier {
        switch platform {
        case .mac:
            // ★ Lil is the FRONT at every Mac size (2026-08-11, Kev: "lil is our
            // snappy, witty agent — and big is for deep reasoning"). Big used to
            // be the automatic pick at 24GB+, which is precisely why a 64GB Mac
            // woke on the SLOWEST brain it could choose. Measured same-build,
            // same fixtures, live path: lil 10,022ms median (max 18,132) vs big
            // 30,500ms (max 289,020) — 3x slower with a tail that blew the 120s
            // MCP deadline on an ordinary question.
            //
            // Big is NOT retired: still fully selectable (minimumPhysicalMemoryGB
            // 16), still the deep tier, still reached on demand via delegate_deep
            // — see `supportsDeepReasoning`. What changed is only which brain you
            // get without asking.
            switch gigabytes {
            case 16...: .lil
            default: .mini
            }
        case .mobile:
            // Physical RAM OVERSTATES the per-app jetsam budget on iOS/visionOS, and
            // Big (gemma-4-12B, ~7.4GB at inference) exceeds any current mobile budget —
            // so the mobile ladder tops out at Lil, and only on ≥16GB iPad Pro /
            // Vision Pro. Everything smaller stays on Mini (Apple Foundation Models,
            // no MLX footprint). Tunable, and verify-by-launch on real devices.
            switch gigabytes {
            case 16...: .lil
            default: .mini
            }
        }
    }

    /// Which platform class a memory-based recommendation is for. The RAM→tier
    /// ladder differs: on iOS/visionOS physical RAM overstates the usable budget,
    /// so the mobile ladder is deliberately more conservative (see `recommended`).
    public enum DevicePlatform: Sendable, Equatable {
        case mac
        case mobile
    }

    /// Convenience: the recommendation for the machine we're running on.
    public static var recommendedForThisMac: BrainTier {
        recommended(forPhysicalMemoryGB: physicalMemoryGB)
    }

    /// Ease an AUTOMATIC brain pick down to what this much memory comfortably
    /// runs — never heavier than `recommended(forPhysicalMemoryGB:)`. LOWER-ONLY:
    /// a pick already at or below the comfortable ceiling is returned unchanged;
    /// this never RAISES a tier, because raising would start a silent multi-GB
    /// download the user never asked for (the onboarding flow owns that choice —
    /// see #81's download honesty). The point is to stop auto-routing from keeping
    /// a too-heavy brain on a small Mac (Big has no hard memory floor, so without
    /// this it would ride along on an 8GB machine and thrash swap). Manual
    /// selection is the user's sovereign choice and is deliberately NOT capped.
    public static func capped(
        _ tier: BrainTier, forPhysicalMemoryGB gigabytes: Double, platform: DevicePlatform = .mac
    ) -> BrainTier {
        min(tier, recommended(forPhysicalMemoryGB: gigabytes, platform: platform))
    }

    /// Convenience: `capped` for the machine we're running on.
    public static func cappedForThisMac(_ tier: BrainTier) -> BrainTier {
        capped(tier, forPhysicalMemoryGB: physicalMemoryGB)
    }

    /// Restore-boundary easing: a persisted pick BELOW its tier's hard floor
    /// eases down via `capped` (it would otherwise run while its own picker row
    /// renders locked — stranded); any selectable pick passes through UNTOUCHED.
    /// Deliberately narrower than `capped` alone: an explicit pick that merely
    /// exceeds the RECOMMENDATION ceiling (Big on a 16GB Mac) is legitimate —
    /// demoting it would violate #81's never-touch-an-explicit-pick honesty rule.
    /// Armed by the 12B floor (2026-07-15); a no-op while no tier carried one.
    public static func selectableOrEased(
        _ tier: BrainTier, forPhysicalMemoryGB gigabytes: Double, platform: DevicePlatform = .mac
    ) -> BrainTier {
        tier.isSelectable(forPhysicalMemoryGB: gigabytes, platform: platform)
            ? tier
            : capped(tier, forPhysicalMemoryGB: gigabytes, platform: platform)
    }

    /// Convenience: whether this tier is selectable on the machine we're on.
    public var isSelectableOnThisMac: Bool {
        isSelectable(forPhysicalMemoryGB: Self.physicalMemoryGB)
    }

    private static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }
}
