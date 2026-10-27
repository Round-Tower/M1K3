//
//  EnergyLedger.swift
//  M1K3Inference
//
//  What M1K3's generations cost, kept as a daily rollup (#696 Phase 2). Rule
//  zero: measure, never quote. A tier with no per-token receipt has no rate and
//  its generations are counted as unpriced, never guessed. Lil's and Big's
//  rates are CALIBRATED: watts and tokens from the same build, two powermetrics
//  runs per tier on one Mac, an M1 Max 64 GB (2026-10-27). On another chip a
//  rate is still that M1 Max's figure, not the user's Mac's (`measuredOn`): a
//  surface must say whose before it prints one. `docs/ENERGY_MEASUREMENT.md`
//  holds the method, the error bars and the runs still owed.
//
//  Attribution: each generation is billed to the model that RAN it
//  (`GenerationMetrics.modelID`), never to the brain the picker shows. A deep
//  dive re-points the MLX slot at Big while Lil stays selected, and an audition
//  is not the stock model. (An audition imported under the stock repo's own
//  name carries that name, so it is billed as that tier.) A model no tier
//  names is counted, never priced.
//
//  Kept: token counts per day and tier, never joules. The ledger prices them on
//  read at the table this build ships (`priced(_:)`), so a ruling (unprice
//  Lil) or a calibration re-prices the history, and a tier that loses its rate
//  shows nothing.
//
//  Granularity: the ledger records per GENERATION, from the process-wide
//  GenerationMetricsReporter sink. A tool turn reports two or three times, so
//  the rollup counts `generations`, not turns. A per-turn sum (an answer footer)
//  is Phase 3's and belongs at the responder's turn boundary. Mini (Apple
//  Foundation Models) never reports, so it records nothing. Coverage is
//  generation only: embedding, retrieval and Apple's tool picker are not in it,
//  and a checkpoint-mode tool send reports a one-token prefill (its real
//  prefill is the reuse line's `extend`). The estimate is a floor, not a total.
//
//  Privacy: every stored field is a number, a date or a tier enum. That borrows
//  the 2026-08-30 heartbeat ruling for pulse tags, "structural only": a tag
//  "describes the shape of a window, never its content" (docs/HEARTBEAT_DESIGN.md).
//  The same ruling says a tag's counts are "banded, never exact". This rollup is
//  not a tag: it keeps exact daily counts, on-device, for 30 days (whether that
//  is acceptable is open for Kev), and any pulse line fed from it must band
//  them. A test walks the encoded JSON and the types and fails on any String or
//  Data. A field added later must be Optional (a strip-the-key decode test) and
//  must not be text.
//
//  `suppressed` is the screengrab harness: it reroutes every store but not
//  UserDefaults.standard, so the guard sits on every write
//  (ReviewPromptLedger's reason, its idiom).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.8 (the ledger is
//  TDD'd against a dictionary fake; the Lil rate is a derivation with a ±50 %
//  band and a coverage gap the doc names; the shell wiring is verify-by-launch).
//  Prior: none (new file; ReviewPromptLedger's storage seam and suppression).
//  Review: Kev + claude-opus-5.5, 2026-10-26 (pre-push review fold) — billed by the generating model, not by
//  `selectedBrain` (a deep dive's Big generations were priced at Lil's rate, and an audition at the stock model's);
//  tokens kept and joules priced on read, so Kev's ruling on the derived Lil rate, or a calibration, re-prices the
//  history instead of leaving 30 days of stale joules; `Rate` names its model and its Mac; `record(_ turn:)` dropped
//  (no caller, and nothing measured to store yet); the heartbeat ruling quoted in its own words. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — calibrated. Kev ran two powermetrics receipts per tier on the 1.3.0
//  (541) app, and `power_receipt.py rates` fitted each phase's watts across the samples, timing every
//  generation's prefill and decode by its ttft line. The derived Lil rate (0.060 / 0.434 J) gives way to Lil
//  0.0738 / 0.422 J and Big, newly priced, 0.213 / 1.17 J, the two runs agreeing within 1.2 % and a blind
//  re-derivation within 0.1 %. Mini stays unpriced: it reports no tokens. A test pins each rate to its
//  committed receipts. Confidence 0.85 (two runs per tier, one Mac, one ~800-token prompt shape).

import Foundation
import Observation

/// The tier's raw value ("mini" / "pocket" / "lil" / "big") is its stable
/// persistence key; the ledger stores it, so the enum encodes as that string.
extension BrainTier: Codable {}

public extension BrainTier {
    /// The tier whose STOCK MLX model is `modelID`; nil for anything else (an
    /// audition under its own name, a folder's `dir:` key, an unknown id). Mini
    /// runs no MLX model, so no id names it.
    init?(generatingModelID modelID: String) {
        guard let tier = Self.allCases.first(where: { $0.mlxModelID == modelID }) else { return nil }
        self = tier
    }
}

/// One generation's energy. Exactly the five fields #696 names: no text,
/// nothing that could hold a message.
public struct TurnEnergy: Sendable, Equatable, Codable {
    public let tier: BrainTier
    public let prefillTokens: Int
    public let decodeTokens: Int
    public let joules: Double
    /// True only when every joule came off a counter on this machine. The
    /// coefficient estimate is never measured.
    public let measured: Bool

    public init(tier: BrainTier, prefillTokens: Int, decodeTokens: Int, joules: Double, measured: Bool) {
        self.tier = tier
        self.prefillTokens = prefillTokens
        self.decodeTokens = decodeTokens
        self.joules = joules
        self.measured = measured
    }

    /// prefill × the rate's prefill joules + decode × its decode joules. A
    /// negative count (a broken report) costs nothing rather than credit.
    public static func estimate(
        tier: BrainTier, prefillTokens: Int, decodeTokens: Int, rate: EnergyCoefficients.Rate
    ) -> TurnEnergy {
        let joules = Double(max(0, prefillTokens)) * rate.joulesPerPrefillToken
            + Double(max(0, decodeTokens)) * rate.joulesPerDecodeToken
        return TurnEnergy(
            tier: tier, prefillTokens: prefillTokens, decodeTokens: decodeTokens, joules: joules, measured: false
        )
    }
}

/// The per-tier joules-per-token table, in one place. `nil` = unpriced: no
/// per-token receipt for that tier (Mini is measured per answer, but reports
/// no tokens), so it gets no number.
public enum EnergyCoefficients {
    public struct Rate: Sendable, Equatable {
        public let joulesPerPrefillToken: Double
        public let joulesPerDecodeToken: Double
        /// True only when powermetrics receipts on one build measured this
        /// tier's watts and token counts together.
        public let calibrated: Bool
        /// The model the rate was measured for. A test binds each to its
        /// tier's `mlxModelID`, so a model swap forces a new receipt.
        public let modelID: String
        /// The Mac the watts were measured on. The rate is that Mac's figure.
        public let measuredOn: String

        public init(
            joulesPerPrefillToken: Double, joulesPerDecodeToken: Double, calibrated: Bool, modelID: String,
            measuredOn: String
        ) {
            self.joulesPerPrefillToken = joulesPerPrefillToken
            self.joulesPerDecodeToken = joulesPerDecodeToken
            self.calibrated = calibrated
            self.modelID = modelID
            self.measuredOn = measuredOn
        }
    }

    public static func rate(for tier: BrainTier) -> Rate? {
        switch tier {
        case .lil: lil
        case .big: big
        // Mini reports no tokens, so a per-token rate would price nothing (its
        // receipt prices an answer instead); pocket has no receipt.
        case .mini, .pocket: nil
        }
    }

    // Both rates: M1 Max 64 GB, AC, the 1.3.0 (541) app, 2026-10-27. Two
    // powermetrics runs of ten `m1k3 ask` answers each; each phase's watts
    // above idle fitted across the samples, with every generation's prefill
    // and decode timed by its ttft line (`tools/eval/power_receipt.py rates`).
    // Each rate is phase joules over phase tokens, both runs pooled, to three
    // figures. The receipts are docs/evals/2026-10-27-power-rates-<tier>-run<N>.json,
    // and a test holds each constant to within 1 % of them.

    /// Lil: prefill drew 47 W above idle, decode 35 W (runs 0.0741 / 0.0736 J
    /// per prefilled token, 0.4214 / 0.4223 per decoded).
    static let lil = Rate(
        joulesPerPrefillToken: 0.0738,
        joulesPerDecodeToken: 0.422,
        calibrated: true,
        modelID: "mlx-community/Qwen3.5-4B-MLX-4bit",
        measuredOn: "Apple M1 Max, 64 GB"
    )

    /// Big: prefill drew 48 W above idle, decode 37 W (runs 0.2142 / 0.2116 J
    /// per prefilled token, 1.1739 / 1.1659 per decoded).
    static let big = Rate(
        joulesPerPrefillToken: 0.213,
        joulesPerDecodeToken: 1.17,
        calibrated: true,
        modelID: "mlx-community/gemma-4-12B-it-4bit",
        measuredOn: "Apple M1 Max, 64 GB"
    )
}

/// One calendar day's token counts, per tier. Numbers, a date and tier enums
/// only, and no joules: the ledger prices the tokens on read.
public struct DailyEnergyRollup: Sendable, Equatable, Codable {
    public struct TierTotal: Sendable, Equatable, Codable {
        public let tier: BrainTier
        public private(set) var generations: Int
        /// The tokens prefilled (the compute, not the context), summed.
        public private(set) var prefillTokens: Int
        public private(set) var decodeTokens: Int

        public init(tier: BrainTier, generations: Int, prefillTokens: Int, decodeTokens: Int) {
            self.tier = tier
            self.generations = generations
            self.prefillTokens = prefillTokens
            self.decodeTokens = decodeTokens
        }

        /// A negative count (a broken report) adds nothing, as the estimate prices it at nothing.
        mutating func add(prefillTokens prefill: Int, decodeTokens decode: Int) {
            generations += 1
            prefillTokens += max(0, prefill)
            decodeTokens += max(0, decode)
        }
    }

    /// The start of the day in the ledger's calendar.
    public let day: Date
    /// Generations by a model no tier names (an audition, a report with no
    /// model id): counted, never priced, no tokens kept.
    public private(set) var unattributedGenerations: Int
    /// Per tier, priced or not, in the order each tier was first seen that day.
    public private(set) var perTier: [TierTotal]

    public init(day: Date) {
        self.day = day
        unattributedGenerations = 0
        perTier = []
    }

    /// Every generation recorded that day.
    public var generations: Int {
        perTier.reduce(unattributedGenerations) { $0 + $1.generations }
    }

    /// The day's tokens priced at `rate`. A tier with no rate, and every
    /// unattributed generation, counts as unpriced and adds no joules.
    public func priced(by rate: (BrainTier) -> EnergyCoefficients.Rate?) -> PricedEnergy {
        var joules = 0.0
        var pricedGenerations = 0
        var unpricedGenerations = unattributedGenerations
        var perTierJoules: [PricedEnergy.TierJoules] = []
        for total in perTier {
            guard let rate = rate(total.tier) else {
                unpricedGenerations += total.generations
                continue
            }
            let tierJoules = Double(total.prefillTokens) * rate.joulesPerPrefillToken
                + Double(total.decodeTokens) * rate.joulesPerDecodeToken
            joules += tierJoules
            pricedGenerations += total.generations
            perTierJoules.append(.init(tier: total.tier, generations: total.generations, joules: tierJoules))
        }
        return PricedEnergy(
            joules: joules, pricedGenerations: pricedGenerations, unpricedGenerations: unpricedGenerations,
            perTier: perTierJoules
        )
    }

    mutating func add(tier: BrainTier, prefillTokens: Int, decodeTokens: Int) {
        if let index = perTier.firstIndex(where: { $0.tier == tier }) {
            perTier[index].add(prefillTokens: prefillTokens, decodeTokens: decodeTokens)
        } else {
            var total = TierTotal(tier: tier, generations: 0, prefillTokens: 0, decodeTokens: 0)
            total.add(prefillTokens: prefillTokens, decodeTokens: decodeTokens)
            perTier.append(total)
        }
    }

    mutating func addUnattributed() {
        unattributedGenerations += 1
    }
}

/// A day's tokens priced at a rate table, on read. Never persisted.
public struct PricedEnergy: Sendable, Equatable {
    public struct TierJoules: Sendable, Equatable {
        public let tier: BrainTier
        public let generations: Int
        public let joules: Double

        public init(tier: BrainTier, generations: Int, joules: Double) {
            self.tier = tier
            self.generations = generations
            self.joules = joules
        }
    }

    public let joules: Double
    public let pricedGenerations: Int
    /// Generations on a tier with no rate, plus those no tier names.
    public let unpricedGenerations: Int
    /// The priced tiers only, in the order each was first seen that day.
    public let perTier: [TierJoules]

    public init(joules: Double, pricedGenerations: Int, unpricedGenerations: Int, perTier: [TierJoules]) {
        self.joules = joules
        self.pricedGenerations = pricedGenerations
        self.unpricedGenerations = unpricedGenerations
        self.perTier = perTier
    }
}

/// What the ledger needs from its store. `UserDefaults` conforms unchanged.
public protocol EnergyLedgerStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: EnergyLedgerStorage {}

@MainActor
@Observable
public final class EnergyLedger {
    /// One JSON blob of `[DailyEnergyRollup]`, oldest first.
    public static let daysKey = "energy.days"
    /// Days kept, today included.
    public static let historyCap = 30

    /// The kept days, oldest first; the newest may be today.
    public private(set) var days: [DailyEnergyRollup]

    private let storage: EnergyLedgerStorage
    private let rate: (BrainTier) -> EnergyCoefficients.Rate?
    private let suppressed: () -> Bool
    private let now: () -> Date
    private let calendar: Calendar

    public init(
        storage: EnergyLedgerStorage,
        rate: @escaping (BrainTier) -> EnergyCoefficients.Rate? = EnergyCoefficients.rate(for:),
        suppressed: @escaping () -> Bool = { false },
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.storage = storage
        self.rate = rate
        self.suppressed = suppressed
        self.now = now
        self.calendar = calendar
        // An unreadable blob (a downgrade, a tier this build does not know)
        // starts an empty history; the next record replaces it.
        days = (storage.object(forKey: Self.daysKey) as? Data)
            .flatMap { try? JSONDecoder().decode([DailyEnergyRollup].self, from: $0) } ?? []
    }

    /// Today's token counts; an empty rollup until today's first generation.
    public var today: DailyEnergyRollup {
        let day = calendar.startOfDay(for: now())
        return days.last(where: { $0.day == day }) ?? DailyEnergyRollup(day: day)
    }

    /// A rollup priced at this ledger's rate table (the shipped one, in the app).
    public func priced(_ rollup: DailyEnergyRollup) -> PricedEnergy {
        rollup.priced(by: rate)
    }

    /// Record one generation, billed to the model that ran it
    /// (`metrics.modelID`), not to the brain the picker shows. Its tokens are
    /// kept whatever the rate. Returns this generation's estimate; nil when it
    /// is unpriced (no tier names its model, or the tier has no rate) or the
    /// ledger is suppressed (nothing written).
    @discardableResult
    public func record(metrics: GenerationMetrics) -> TurnEnergy? {
        guard !suppressed() else { return nil }
        guard let tier = metrics.modelID.flatMap(BrainTier.init(generatingModelID:)) else {
            update { $0.addUnattributed() }
            return nil
        }
        let prefill = metrics.prefilledTokens ?? metrics.promptTokens
        update { $0.add(tier: tier, prefillTokens: prefill, decodeTokens: metrics.generationTokens) }
        return rate(tier).map {
            TurnEnergy.estimate(tier: tier, prefillTokens: prefill, decodeTokens: metrics.generationTokens, rate: $0)
        }
    }

    private func update(_ change: (inout DailyEnergyRollup) -> Void) {
        let day = calendar.startOfDay(for: now())
        if let index = days.lastIndex(where: { $0.day == day }) {
            change(&days[index])
        } else {
            var fresh = DailyEnergyRollup(day: day)
            change(&fresh)
            days.append(fresh)
            // A clock set back lands on its own day, in order.
            days.sort { $0.day < $1.day }
            if days.count > Self.historyCap {
                days.removeFirst(days.count - Self.historyCap)
            }
        }
        if let blob = try? JSONEncoder().encode(days) {
            storage.set(blob, forKey: Self.daysKey)
        }
    }
}
