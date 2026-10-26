//
//  EnergyLedger.swift
//  M1K3Inference
//
//  What M1K3's generations cost on this Mac, kept as a daily rollup (#696
//  Phase 2). Rule zero: measure, never quote. A tier with no watts measured on
//  this Mac has no rate and its generations are counted as unpriced, never
//  guessed. Lil's rate is DERIVED from two measurements on this M1 Max (the
//  2026-09-15 powermetrics receipt's watts and the 2026-10-25 Release
//  throughput), not calibrated in one run, and it says so (`calibrated:
//  false`). `docs/ENERGY_MEASUREMENT.md` holds the method, the error bars and
//  the runs still owed.
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
//  Privacy (structure, not conversation; the 2026-08-30 heartbeat ruling):
//  every stored field is a number, a date or a tier enum. A test walks the
//  encoded JSON and the types and fails on any String or Data. A field added
//  later must be Optional (a strip-the-key decode test) and must not be text.
//
//  `suppressed` is the screengrab harness: it reroutes every store but not
//  UserDefaults.standard, so the guard sits on every write
//  (ReviewPromptLedger's reason, its idiom).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.8 (the ledger is
//  TDD'd against a dictionary fake; the Lil rate is a derivation with a ±50 %
//  band and a coverage gap the doc names; the shell wiring is verify-by-launch).
//  Prior: none (new file; ReviewPromptLedger's storage seam and suppression).

import Foundation
import Observation

/// The tier's raw value ("mini" / "pocket" / "lil" / "big") is its stable
/// persistence key; the ledger stores it, so the enum encodes as that string.
extension BrainTier: Codable {}

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
/// watts were measured for that tier on this Mac, so it gets no number.
public enum EnergyCoefficients {
    public struct Rate: Sendable, Equatable {
        public let joulesPerPrefillToken: Double
        public let joulesPerDecodeToken: Double
        /// True only when one powermetrics run on the shipping build measured
        /// this tier's watts and throughput together.
        public let calibrated: Bool

        public init(joulesPerPrefillToken: Double, joulesPerDecodeToken: Double, calibrated: Bool) {
            self.joulesPerPrefillToken = joulesPerPrefillToken
            self.joulesPerDecodeToken = joulesPerDecodeToken
            self.calibrated = calibrated
        }
    }

    public static func rate(for tier: BrainTier) -> Rate? {
        switch tier {
        case .lil: lilDerived
        // Owed: a sudo powermetrics run per tier (docs/ENERGY_MEASUREMENT.md).
        case .mini, .pocket, .big: nil
        }
    }

    /// Lil (M1 Max 64 GB, AC): package watts above idle ÷ tokens per second.
    /// The watts are POWER_RECEIPT run 1 (2026-09-15, Qwen3-4B DWQ, median
    /// 37.14 W during an answer, idle 1.09 W); the throughput is the
    /// 2026-10-25 Release baseline (Qwen3.5-4B: decode 83 tok/s, prefill
    /// ~600 tok/s past the persona seed). Two runs, two models, one Mac,
    /// hence uncalibrated: about 0.43 J per decoded token, 0.06 J per prefilled.
    static let lilDerived: Rate = {
        let wattsAboveIdle = 37.14 - 1.09
        let decodeTokensPerSecond = 83.0
        let prefillTokensPerSecond = 600.0
        return Rate(
            joulesPerPrefillToken: wattsAboveIdle / prefillTokensPerSecond,
            joulesPerDecodeToken: wattsAboveIdle / decodeTokensPerSecond,
            calibrated: false
        )
    }()
}

/// One calendar day's totals. Numbers, a date and tier enums only.
public struct DailyEnergyRollup: Sendable, Equatable, Codable {
    public struct TierTotal: Sendable, Equatable, Codable {
        public let tier: BrainTier
        public private(set) var generations: Int
        public private(set) var joules: Double

        public init(tier: BrainTier, generations: Int, joules: Double) {
            self.tier = tier
            self.generations = generations
            self.joules = joules
        }

        mutating func add(_ turn: TurnEnergy) {
            generations += 1
            joules += turn.joules
        }
    }

    /// The start of the day in the ledger's calendar.
    public let day: Date
    /// Priced generations.
    public private(set) var generations: Int
    public private(set) var joules: Double
    /// Generations on a tier with no rate: counted, never priced.
    public private(set) var unpricedGenerations: Int
    /// Priced totals per tier, in the order each tier was first seen that day.
    public private(set) var perTier: [TierTotal]

    public init(day: Date) {
        self.day = day
        generations = 0
        joules = 0
        unpricedGenerations = 0
        perTier = []
    }

    mutating func add(_ turn: TurnEnergy) {
        generations += 1
        joules += turn.joules
        if let index = perTier.firstIndex(where: { $0.tier == turn.tier }) {
            perTier[index].add(turn)
        } else {
            var total = TierTotal(tier: turn.tier, generations: 0, joules: 0)
            total.add(turn)
            perTier.append(total)
        }
    }

    mutating func addUnpriced() {
        unpricedGenerations += 1
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

    /// Today's totals; an empty rollup until today's first generation.
    public var today: DailyEnergyRollup {
        let day = calendar.startOfDay(for: now())
        return days.last(where: { $0.day == day }) ?? DailyEnergyRollup(day: day)
    }

    /// Price one generation's metrics at its tier's rate and record it.
    /// Returns what was recorded; nil when the tier is unpriced (counted as
    /// such) or the ledger is suppressed (nothing written).
    @discardableResult
    public func record(metrics: GenerationMetrics, tier: BrainTier) -> TurnEnergy? {
        guard !suppressed() else { return nil }
        guard let rate = rate(tier) else {
            update { $0.addUnpriced() }
            return nil
        }
        let turn = TurnEnergy.estimate(
            tier: tier,
            prefillTokens: metrics.prefilledTokens ?? metrics.promptTokens,
            decodeTokens: metrics.generationTokens,
            rate: rate
        )
        update { $0.add(turn) }
        return turn
    }

    /// Record an energy figure as given (a measured one, in a later phase).
    public func record(_ turn: TurnEnergy) {
        guard !suppressed() else { return }
        update { $0.add(turn) }
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
