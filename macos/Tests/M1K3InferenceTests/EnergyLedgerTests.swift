//
//  EnergyLedgerTests.swift
//  M1K3InferenceTests
//
//  The energy ledger (#696 Phase 2): the coefficient estimate, the per-tier
//  table (Lil derived, the rest unpriced), the daily rollup with its day
//  rollover and 30-day cap, persistence through a dictionary storage fake
//  (`swift test` is unsandboxed; a UserDefaults suite would leave a plist
//  behind), the screengrab suppression, and the privacy pin: no field the
//  ledger keeps can hold message text. Clocks are injected — no sleeping, no
//  wall-clock bound.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.85. Prior: none (new file).

import Foundation
@testable import M1K3Inference
import Testing

@MainActor
struct EnergyLedgerTests {
    /// Dictionary-backed storage — what UserDefaults is to the shell.
    private final class MemoryStorage: EnergyLedgerStorage {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? {
            values[key]
        }

        func set(_ value: Any?, forKey key: String) {
            if let value { values[key] = value } else { values.removeValue(forKey: key) }
        }
    }

    /// A clock the test moves by hand.
    private final class Clock {
        var now: Date
        init(_ now: Date) {
            self.now = now
        }
    }

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86400
    private let rate = EnergyCoefficients.Rate(joulesPerPrefillToken: 0.06, joulesPerDecodeToken: 0.43, calibrated: false)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func ledger(
        storage: MemoryStorage,
        clock: Clock? = nil,
        rate: EnergyCoefficients.Rate?? = nil,
        suppressed: Bool = false
    ) -> EnergyLedger {
        let clock = clock ?? Clock(epoch)
        let fixed = rate ?? self.rate
        return EnergyLedger(
            storage: storage,
            rate: { _ in fixed },
            suppressed: { suppressed },
            now: { clock.now },
            calendar: utc
        )
    }

    private func metrics(prompt: Int, decode: Int, prefilled: Int? = nil) -> GenerationMetrics {
        GenerationMetrics(promptTokens: prompt, generationTokens: decode, tokensPerSecond: 80, prefilledTokens: prefilled)
    }

    // MARK: - The estimate and the table

    @Test("estimate is prefill × a + decode × b, never measured; zero or negative tokens cost nothing")
    func estimateMaths() {
        let turn = TurnEnergy.estimate(tier: .lil, prefillTokens: 100, decodeTokens: 200, rate: rate)
        #expect(turn == TurnEnergy(
            tier: .lil, prefillTokens: 100, decodeTokens: 200, joules: 100 * 0.06 + 200 * 0.43, measured: false
        ))
        #expect(TurnEnergy.estimate(tier: .lil, prefillTokens: 0, decodeTokens: 0, rate: rate).joules == 0)
        #expect(TurnEnergy.estimate(tier: .lil, prefillTokens: -5, decodeTokens: -9, rate: rate).joules == 0)
    }

    @Test("the shipped table: Lil derived and uncalibrated, Mini / pocket / Big unpriced until measured")
    func shippedTable() throws {
        let lil = try #require(EnergyCoefficients.rate(for: .lil))
        #expect(lil.calibrated == false)
        #expect(lil.joulesPerPrefillToken > 0 && lil.joulesPerPrefillToken.isFinite)
        #expect(lil.joulesPerDecodeToken > lil.joulesPerPrefillToken)
        // Rule zero: no watts measured on this Mac for these tiers, so no number.
        #expect(EnergyCoefficients.rate(for: .mini) == nil)
        #expect(EnergyCoefficients.rate(for: .pocket) == nil)
        #expect(EnergyCoefficients.rate(for: .big) == nil)
    }

    // MARK: - Recording

    @Test("a tier with no rate prices nothing and counts one unpriced generation")
    func unpricedTier() {
        let storage = MemoryStorage()
        let ledger = ledger(storage: storage, rate: .some(nil))
        #expect(ledger.record(metrics: metrics(prompt: 900, decode: 40), tier: .big) == nil)
        #expect(ledger.today.generations == 0)
        #expect(ledger.today.unpricedGenerations == 1)
        #expect(ledger.today.joules == 0)
        #expect(ledger.today.perTier.isEmpty)
        #expect(storage.values[EnergyLedger.daysKey] != nil)
    }

    @Test("prefilledTokens is priced when present; promptTokens only when it is not")
    func prefilledWins() throws {
        let ledger = ledger(storage: MemoryStorage())
        let warm = try #require(ledger.record(metrics: metrics(prompt: 2444, decode: 10, prefilled: 57), tier: .lil))
        #expect(warm.prefillTokens == 57)
        #expect(warm.decodeTokens == 10)
        let unknown = try #require(ledger.record(metrics: metrics(prompt: 2444, decode: 10), tier: .lil))
        #expect(unknown.prefillTokens == 2444)
    }

    @Test("two generations fold into today's rollup and per-tier totals, persisted as one blob")
    func twoGenerationsFold() throws {
        let storage = MemoryStorage()
        let ledger = ledger(storage: storage)
        let first = try #require(ledger.record(metrics: metrics(prompt: 300, decode: 120, prefilled: 300), tier: .lil))
        let second = try #require(ledger.record(metrics: metrics(prompt: 500, decode: 80, prefilled: 60), tier: .lil))
        let sum = first.joules + second.joules
        #expect(ledger.today.generations == 2)
        #expect(ledger.today.joules == sum)
        #expect(ledger.today.perTier == [DailyEnergyRollup.TierTotal(tier: .lil, generations: 2, joules: sum)])
        let blob = try #require(storage.values[EnergyLedger.daysKey] as? Data)
        let stored = try JSONDecoder().decode([DailyEnergyRollup].self, from: blob)
        #expect(stored.last == ledger.today)
    }

    @Test("per-tier totals keep each tier apart, in the order first seen")
    func perTierApart() {
        let ledger = ledger(storage: MemoryStorage())
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100), tier: .lil)
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100), tier: .big)
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100), tier: .lil)
        #expect(ledger.today.perTier.map(\.tier) == [.lil, .big])
        #expect(ledger.today.perTier.map(\.generations) == [2, 1])
        #expect(ledger.today.generations == 3)
    }

    @Test("an explicit TurnEnergy records as given, measured flag and all")
    func recordTurnDirectly() {
        let ledger = ledger(storage: MemoryStorage())
        ledger.record(TurnEnergy(tier: .lil, prefillTokens: 10, decodeTokens: 20, joules: 4.5, measured: true))
        #expect(ledger.today.joules == 4.5)
        #expect(ledger.today.generations == 1)
    }

    // MARK: - Days

    @Test("a new calendar day starts a fresh rollup and keeps yesterday")
    func dayRollover() {
        let clock = Clock(epoch)
        let ledger = ledger(storage: MemoryStorage(), clock: clock)
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100), tier: .lil)
        clock.now = epoch.addingTimeInterval(day * 1.5)
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100), tier: .lil)
        #expect(ledger.days.count == 2)
        #expect(ledger.days[0].day == utc.startOfDay(for: epoch))
        #expect(ledger.days[0].generations == 1)
        #expect(ledger.today.generations == 1)
        #expect(ledger.today.day == utc.startOfDay(for: clock.now))
    }

    @Test("after midnight with nothing recorded yet, today reads empty and history is untouched")
    func todayIsEmptyAfterMidnight() {
        let clock = Clock(epoch)
        let ledger = ledger(storage: MemoryStorage(), clock: clock)
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100), tier: .lil)
        clock.now = epoch.addingTimeInterval(day)
        #expect(ledger.today.generations == 0)
        #expect(ledger.today.joules == 0)
        #expect(ledger.today.day == utc.startOfDay(for: clock.now))
        #expect(ledger.days.count == 1)
    }

    @Test("history is capped at 30 days, oldest dropped")
    func thirtyDayCap() {
        let clock = Clock(epoch)
        let ledger = ledger(storage: MemoryStorage(), clock: clock)
        for offset in 0 ..< 31 {
            clock.now = epoch.addingTimeInterval(day * Double(offset))
            ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100), tier: .lil)
        }
        #expect(ledger.days.count == EnergyLedger.historyCap)
        #expect(EnergyLedger.historyCap == 30)
        #expect(ledger.days.first?.day == utc.startOfDay(for: epoch.addingTimeInterval(day)))
    }

    @Test("a clock set back lands on its own day, in order, without disturbing the newest")
    func clockSetBack() {
        let clock = Clock(epoch.addingTimeInterval(day * 2))
        let ledger = ledger(storage: MemoryStorage(), clock: clock)
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100), tier: .lil)
        clock.now = epoch
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100), tier: .lil)
        #expect(ledger.days.map(\.day) == [utc.startOfDay(for: epoch), utc.startOfDay(for: epoch.addingTimeInterval(day * 2))])
    }

    // MARK: - Storage

    @Test("a fresh ledger reloads the persisted days")
    func reloads() {
        let storage = MemoryStorage()
        let first = ledger(storage: storage)
        first.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100), tier: .lil)
        first.record(metrics: metrics(prompt: 100, decode: 10), tier: .lil)
        let second = ledger(storage: storage)
        #expect(second.days == first.days)
        #expect(second.today == first.today)
    }

    @Test("an unreadable blob starts an empty history instead of crashing, and the next record replaces it")
    func corruptStorage() throws {
        let storage = MemoryStorage()
        storage.values[EnergyLedger.daysKey] = Data("not json".utf8)
        let ledger = ledger(storage: storage)
        #expect(ledger.days.isEmpty)
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100), tier: .lil)
        let blob = try #require(storage.values[EnergyLedger.daysKey] as? Data)
        #expect(try JSONDecoder().decode([DailyEnergyRollup].self, from: blob).count == 1)
    }

    @Test("suppressed (the screengrab harness) records and writes nothing")
    func suppressedWritesNothing() {
        let storage = MemoryStorage()
        let ledger = ledger(storage: storage, suppressed: true)
        #expect(ledger.record(metrics: metrics(prompt: 100, decode: 10), tier: .lil) == nil)
        ledger.record(TurnEnergy(tier: .lil, prefillTokens: 1, decodeTokens: 1, joules: 1, measured: false))
        #expect(storage.values.isEmpty)
        #expect(ledger.today.generations == 0)
        #expect(ledger.days.isEmpty)
    }

    // MARK: - Privacy pin

    @Test("PRIVACY PIN: no ledger field can hold message text — exact keys, numeric leaves, no String in the types")
    func privacyPin() throws {
        let turn = TurnEnergy(tier: .lil, prefillTokens: 10, decodeTokens: 20, joules: 3, measured: false)
        let ledger = ledger(storage: MemoryStorage())
        ledger.record(turn)
        ledger.record(metrics: metrics(prompt: 1, decode: 1), tier: .big)
        let rollup = ledger.today

        #expect(try jsonKeys(turn) == ["tier", "prefillTokens", "decodeTokens", "joules", "measured"])
        #expect(try jsonKeys(rollup) == ["day", "generations", "joules", "unpricedGenerations", "perTier"])
        #expect(try jsonKeys(rollup.perTier[0]) == ["tier", "generations", "joules"])

        // Every JSON leaf is a number or bool; the ONLY string allowed is a tier name.
        for value in try [JSONEncoder().encode(turn), JSONEncoder().encode([rollup])] {
            for leaf in try jsonLeaves(JSONSerialization.jsonObject(with: value)) {
                if let text = leaf as? String {
                    #expect(BrainTier(rawValue: text) != nil, "a string leaf that is not a tier: \(text)")
                } else {
                    #expect(leaf is NSNumber)
                }
            }
        }
        // And by type: nothing reachable from the values is String / Substring / Character / Data.
        #expect(textLeaks(in: turn).isEmpty)
        #expect(textLeaks(in: rollup).isEmpty)
    }

    @Test("positive control: the same walker DOES find text fields, set, nil or empty (proves the pin can fail)")
    func privacyPinPositiveControl() {
        struct Decoy {
            let joules: Double
            let note: String?
            let unset: String?
            let tags: [String]
            let blob: Data?
            let perTier: [DailyEnergyRollup.TierTotal]
        }
        let decoy = Decoy(
            joules: 1, note: "what the user asked", unset: nil, tags: [], blob: nil,
            perTier: [.init(tier: .lil, generations: 1, joules: 1)]
        )
        #expect(textLeaks(in: decoy) == ["root.note", "root.unset", "root.tags", "root.blob"])
    }

    private func jsonKeys(_ value: some Encodable) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return Set((object as? [String: Any])?.keys.map(\.self) ?? [])
    }

    private func jsonLeaves(_ object: Any) -> [Any] {
        if let dictionary = object as? [String: Any] { return dictionary.values.flatMap(jsonLeaves) }
        if let array = object as? [Any] { return array.flatMap(jsonLeaves) }
        return [object]
    }

    /// By the value's dynamic TYPE, so a nil `String?` or an empty `[String]` is
    /// caught too (a value check alone would find nothing inside them).
    private func textLeaks(in value: Any, path: String = "root") -> [String] {
        let typeName = String(reflecting: type(of: value))
        let textTypes = ["Swift.String", "Swift.Substring", "Swift.Character", "Foundation.Data"]
        if textTypes.contains(where: typeName.contains) { return [path] }
        return Mirror(reflecting: value).children.enumerated().flatMap { index, child in
            textLeaks(in: child.value, path: path + "." + (child.label ?? "\(index)"))
        }
    }
}
