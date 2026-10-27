//
//  EnergyLedgerTests.swift
//  M1K3InferenceTests
//
//  The energy ledger (#696 Phase 2): the coefficient estimate, the per-tier
//  table (Lil and Big calibrated, Mini and pocket unpriced), the model → tier resolver, the
//  daily rollup with its day rollover and 30-day cap, pricing on read,
//  persistence through a dictionary storage fake (`swift test` is unsandboxed;
//  a UserDefaults suite would leave a plist behind), the screengrab
//  suppression, the shell's wiring, and the privacy pin: no field the ledger
//  keeps can hold message text. Clocks are injected — no sleeping, no
//  wall-clock bound.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.85. Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-26 (pre-push review fold) — the ledger attributes each generation to the
//  model that ran it and keeps token counts, priced on read. New pins: the model → tier resolver; a deep dive's Big
//  generation stays Big's (unpriced) whatever rate Lil has; an audition is counted, never priced; the production
//  default table (Lil at the doc's 0.060 / 0.434 J, bound to Lil's model id; Big and pocket unpriced); history
//  re-priced by a new table; the shell wiring read off AppEnvironment.swift. Test rates are exact binary fractions,
//  so a priced-on-read total equals the sum of the per-generation estimates bit for bit. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-26 (CI fold) — repricedOnRead's expected joules are typed Double constants:
//  CI's Swift 6.3 timed out type-checking `100 * 0.5 + 10 * 2` inside #expect (twice on bc5d22a1), Swift 6.4 did not.
//  Same values, no logic change. Confidence 0.9.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — the calibration: Lil and Big are priced from Kev's two same-build
//  powermetrics runs per tier, and a new pin reads the committed phase receipts (docs/evals/2026-10-27-power-rates-*)
//  and holds each shipped rate to within 1 % of its tier's two runs pooled, so a constant can't drift from its
//  evidence. The shipped-table and production-default pins now expect Lil 0.0738 / 0.422 and Big 0.213 / 1.17 J,
//  both calibrated, each bound to its tier's model id; Mini and pocket stay unpriced. A source scan holds the
//  doc's rate table to the shipped constants (the doc drifted from them three times while this was made).
//  Confidence 0.85.

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
    /// Exact binary fractions: sums and products stay exact, so totals compare with `==`.
    private let rate = EnergyCoefficients.Rate(
        joulesPerPrefillToken: 0.5, joulesPerDecodeToken: 2, calibrated: false,
        modelID: "test-model", measuredOn: "a test"
    )

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A ledger on an injected clock and UTC calendar. `rate` nil prices every tier at the fixed test rate.
    private func ledger(
        storage: MemoryStorage,
        clock: Clock? = nil,
        rate: ((BrainTier) -> EnergyCoefficients.Rate?)? = nil,
        suppressed: Bool = false
    ) -> EnergyLedger {
        let clock = clock ?? Clock(epoch)
        let fixed = self.rate
        return EnergyLedger(
            storage: storage,
            rate: rate ?? { _ in fixed },
            suppressed: { suppressed },
            now: { clock.now },
            calendar: utc
        )
    }

    /// One generation's report, by default from Lil's stock model.
    private func metrics(
        prompt: Int, decode: Int, prefilled: Int? = nil, model: String? = BrainTier.lil.mlxModelID
    ) -> GenerationMetrics {
        GenerationMetrics(
            promptTokens: prompt, generationTokens: decode, tokensPerSecond: 80, prefilledTokens: prefilled,
            modelID: model
        )
    }

    // MARK: - The estimate, the table, the resolver

    @Test("estimate is prefill × a + decode × b, never measured; zero or negative tokens cost nothing")
    func estimateMaths() {
        let rate = EnergyCoefficients.Rate(
            joulesPerPrefillToken: 0.06, joulesPerDecodeToken: 0.43, calibrated: false, modelID: "m", measuredOn: "x"
        )
        let turn = TurnEnergy.estimate(tier: .lil, prefillTokens: 100, decodeTokens: 200, rate: rate)
        #expect(turn == TurnEnergy(
            tier: .lil, prefillTokens: 100, decodeTokens: 200, joules: 100 * 0.06 + 200 * 0.43, measured: false
        ))
        #expect(TurnEnergy.estimate(tier: .lil, prefillTokens: 0, decodeTokens: 0, rate: rate).joules == 0)
        #expect(TurnEnergy.estimate(tier: .lil, prefillTokens: -5, decodeTokens: -9, rate: rate).joules == 0)
    }

    @Test("the shipped table: Lil and Big calibrated at the doc's rates, each bound to its model; Mini and pocket unpriced")
    func shippedTable() throws {
        let lil = try #require(EnergyCoefficients.rate(for: .lil))
        let big = try #require(EnergyCoefficients.rate(for: .big))
        #expect(lil == EnergyCoefficients.lil)
        #expect(big == EnergyCoefficients.big)
        // docs/ENERGY_MEASUREMENT.md quotes these four: the doc and the code move together.
        #expect(abs(lil.joulesPerPrefillToken - 0.0738) < 0.00005)
        #expect(abs(lil.joulesPerDecodeToken - 0.422) < 0.0005)
        #expect(abs(big.joulesPerPrefillToken - 0.213) < 0.0005)
        #expect(abs(big.joulesPerDecodeToken - 1.17) < 0.0005)
        for (tier, rate) in [(BrainTier.lil, lil), (BrainTier.big, big)] {
            // Watts and tokens from one build: calibrated. A model swap fails here and forces a new receipt.
            #expect(rate.calibrated, "\(tier)")
            #expect(rate.modelID == tier.mlxModelID, "\(tier)")
            #expect(rate.measuredOn == "Apple M1 Max, 64 GB", "\(tier)")
        }
        // Mini reports no tokens, so a per-token rate would price nothing; pocket has no receipt.
        #expect(EnergyCoefficients.rate(for: .mini) == nil)
        #expect(EnergyCoefficients.rate(for: .pocket) == nil)
    }

    /// The fields of a `power_receipt.py rates` file this pin reads.
    private struct PhaseReceipt: Decodable {
        let model: String
        let prefillTokens: Int
        let decodeTokens: Int
        let prefillJoules: Double
        let decodeJoules: Double
    }

    @Test("each shipped rate is its tier's two committed receipts pooled (phase joules over tokens), to within 1 %")
    func ratesAreThePooledReceipts() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for (tier, name) in [(BrainTier.lil, "lil"), (BrainTier.big, "big")] {
            let rate = try #require(EnergyCoefficients.rate(for: tier))
            var prefillJoules = 0.0, decodeJoules = 0.0, prefillTokens = 0, decodeTokens = 0
            for run in 1 ... 2 {
                let url = try Self.packageRoot().appending(path: "docs/evals/2026-10-27-power-rates-\(name)-run\(run).json")
                let receipt = try decoder.decode(PhaseReceipt.self, from: Data(contentsOf: url))
                #expect(receipt.model == rate.modelID, "\(name) run \(run) measured another model")
                prefillJoules += receipt.prefillJoules
                decodeJoules += receipt.decodeJoules
                prefillTokens += receipt.prefillTokens
                decodeTokens += receipt.decodeTokens
            }
            let pooledPrefill: Double = prefillJoules / Double(prefillTokens)
            let pooledDecode: Double = decodeJoules / Double(decodeTokens)
            let prefillGap: Double = abs(rate.joulesPerPrefillToken - pooledPrefill) / pooledPrefill
            let decodeGap: Double = abs(rate.joulesPerDecodeToken - pooledDecode) / pooledDecode
            #expect(prefillGap < 0.01, "\(name) prefill")
            #expect(decodeGap < 0.01, "\(name) decode")
        }
    }

    @Test("the doc's rate table quotes the shipped rates, so docs/ENERGY_MEASUREMENT.md moves with the code")
    func docQuotesTheShippedRates() throws {
        let url = try Self.packageRoot().appending(path: "docs/ENERGY_MEASUREMENT.md")
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        for (tier, name) in [(BrainTier.lil, "Lil"), (BrainTier.big, "Big")] {
            let rate = try #require(EnergyCoefficients.rate(for: tier))
            let row = try #require(rows.first { $0.hasPrefix("| \(name) |") }, "no \(name) row in the rate table")
            #expect(row.contains("**\(rate.joulesPerPrefillToken)**"), "\(name) prefill: \(row)")
            #expect(row.contains("**\(rate.joulesPerDecodeToken)**"), "\(name) decode: \(row)")
            #expect(row.contains("**yes**") == rate.calibrated, "\(name) calibrated: \(row)")
        }
    }

    @Test("a model id names a tier only when it is that tier's stock model; anything else names none")
    func tierFromModelID() {
        for tier in BrainTier.allCases {
            guard let id = tier.mlxModelID else { continue }
            #expect(BrainTier(generatingModelID: id) == tier, "\(tier) must round-trip through its own model id")
        }
        #expect(BrainTier.mini.mlxModelID == nil, "Mini runs no MLX model, so no id resolves to it")
        #expect(BrainTier(generatingModelID: "mlx-community/Ministral-3-3B-Instruct-4bit") == nil, "an audition")
        #expect(BrainTier(generatingModelID: "dir:/Users/someone/models/mlx-community/Qwen3.5-4B-MLX-4bit") == nil)
        #expect(BrainTier(generatingModelID: "") == nil)
        #expect(BrainTier(generatingModelID: "lil") == nil, "a tier's raw name is not a model id")
    }

    // MARK: - Recording

    @Test("billed to the model that ran: a deep dive's Big generation stays Big's whatever rate table is injected")
    func billedByGeneratingModel() {
        let lilOnly = rate
        let ledger = ledger(storage: MemoryStorage(), rate: { $0 == .lil ? lilOnly : nil })
        #expect(ledger.record(metrics: metrics(prompt: 900, decode: 400, model: BrainTier.big.mlxModelID)) == nil)
        #expect(ledger.today.perTier.map(\.tier) == [.big])
        let priced = ledger.priced(ledger.today)
        #expect(priced.pricedGenerations == 0)
        #expect(priced.unpricedGenerations == 1)
        #expect(priced.joules == 0)
        #expect(priced.perTier.isEmpty)
    }

    @Test("a model no tier names (an audition, a report with no id) is counted, never priced, and keeps no tokens")
    func unattributedModel() {
        let storage = MemoryStorage()
        let ledger = ledger(storage: storage)
        let audition = metrics(prompt: 900, decode: 40, model: "mlx-community/Ministral-3-3B-Instruct-4bit")
        #expect(ledger.record(metrics: audition) == nil)
        #expect(ledger.record(metrics: metrics(prompt: 900, decode: 40, model: nil)) == nil)
        #expect(ledger.today.unattributedGenerations == 2)
        #expect(ledger.today.perTier.isEmpty)
        #expect(ledger.today.generations == 2)
        #expect(ledger.priced(ledger.today).unpricedGenerations == 2)
        #expect(ledger.priced(ledger.today).joules == 0)
        #expect(storage.values[EnergyLedger.daysKey] != nil)
    }

    @Test("a tier with no rate keeps its tokens and counts as unpriced, so a later rate can price it")
    func unpricedTier() {
        let storage = MemoryStorage()
        let ledger = ledger(storage: storage, rate: { _ in nil })
        #expect(ledger.record(metrics: metrics(prompt: 900, decode: 40, model: BrainTier.big.mlxModelID)) == nil)
        #expect(ledger.today.perTier == [
            DailyEnergyRollup.TierTotal(tier: .big, generations: 1, prefillTokens: 900, decodeTokens: 40),
        ])
        let priced = ledger.priced(ledger.today)
        #expect(priced.unpricedGenerations == 1)
        #expect(priced.pricedGenerations == 0)
        #expect(priced.joules == 0)
        #expect(priced.perTier.isEmpty)
        #expect(storage.values[EnergyLedger.daysKey] != nil)
    }

    @Test("the production default table prices Lil and Big at their own rates; pocket and a missing id stay unpriced")
    func productionDefaults() throws {
        let clock = Clock(epoch)
        // No `rate:` argument: exactly how AppEnvironment builds it.
        let ledger = EnergyLedger(storage: MemoryStorage(), now: { clock.now }, calendar: utc)
        let lil = try #require(ledger.record(metrics: metrics(prompt: 2444, decode: 10, prefilled: 100)))
        #expect(lil == TurnEnergy.estimate(tier: .lil, prefillTokens: 100, decodeTokens: 10, rate: EnergyCoefficients.lil))
        let big = try #require(ledger.record(metrics: metrics(
            prompt: 2444, decode: 10, prefilled: 100, model: BrainTier.big.mlxModelID
        )))
        // A deep dive's Big generation costs Big's rate, not Lil's.
        #expect(big == TurnEnergy.estimate(tier: .big, prefillTokens: 100, decodeTokens: 10, rate: EnergyCoefficients.big))
        #expect(big.joules > lil.joules)
        for model in [BrainTier.pocket.mlxModelID, nil] {
            #expect(ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100, model: model)) == nil)
        }
        let priced = ledger.priced(ledger.today)
        #expect(priced.pricedGenerations == 2)
        #expect(priced.unpricedGenerations == 2)
        #expect(priced.perTier.map(\.tier) == [.lil, .big])
        let expected: Double = lil.joules + big.joules
        #expect(priced.joules == expected)
        #expect(ledger.today.generations == 4)
    }

    @Test("prefilledTokens is priced when present; promptTokens only when it is not")
    func prefilledWins() throws {
        let ledger = ledger(storage: MemoryStorage())
        let warm = try #require(ledger.record(metrics: metrics(prompt: 2444, decode: 10, prefilled: 57)))
        #expect(warm.prefillTokens == 57)
        #expect(warm.decodeTokens == 10)
        let unknown = try #require(ledger.record(metrics: metrics(prompt: 2444, decode: 10)))
        #expect(unknown.prefillTokens == 2444)
        #expect(ledger.today.perTier.first?.prefillTokens == 57 + 2444)
    }

    @Test("two generations fold into today's tokens; priced on read they cost the sum of their estimates; one blob")
    func twoGenerationsFold() throws {
        let storage = MemoryStorage()
        let ledger = ledger(storage: storage)
        let first = try #require(ledger.record(metrics: metrics(prompt: 300, decode: 120, prefilled: 300)))
        let second = try #require(ledger.record(metrics: metrics(prompt: 500, decode: 80, prefilled: 60)))
        #expect(ledger.today.perTier == [.init(tier: .lil, generations: 2, prefillTokens: 360, decodeTokens: 200)])
        let priced = ledger.priced(ledger.today)
        #expect(priced.pricedGenerations == 2)
        #expect(priced.joules == first.joules + second.joules)
        #expect(priced.perTier == [.init(tier: .lil, generations: 2, joules: first.joules + second.joules)])
        let blob = try #require(storage.values[EnergyLedger.daysKey] as? Data)
        let stored = try JSONDecoder().decode([DailyEnergyRollup].self, from: blob)
        #expect(stored.last == ledger.today)
    }

    @Test("per-tier totals keep each tier apart, in the order first seen")
    func perTierApart() {
        let ledger = ledger(storage: MemoryStorage())
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100))
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100, model: BrainTier.big.mlxModelID))
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100))
        #expect(ledger.today.perTier.map(\.tier) == [.lil, .big])
        #expect(ledger.today.perTier.map(\.generations) == [2, 1])
        #expect(ledger.today.generations == 3)
        #expect(ledger.priced(ledger.today).perTier.map(\.tier) == [.lil, .big])
    }

    @Test("priced on read: a new table re-prices the kept tokens; a tier that loses its rate shows nothing")
    func repricedOnRead() {
        let storage = MemoryStorage()
        let first = ledger(storage: storage)
        first.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100))
        // Typed constants: Swift 6.3 (CI's Xcode 26.6) cannot type-check Double and Int literals mixed inside #expect.
        let derivedJoules: Double = 100 * 0.5 + 10 * 2
        #expect(first.priced(first.today).joules == derivedJoules)

        let doubled = EnergyCoefficients.Rate(
            joulesPerPrefillToken: 1, joulesPerDecodeToken: 4, calibrated: true, modelID: "test-model",
            measuredOn: "a test"
        )
        let calibrated = ledger(storage: storage, rate: { _ in doubled })
        let calibratedJoules: Double = 100 * 1 + 10 * 4
        #expect(calibrated.priced(calibrated.today).joules == calibratedJoules)

        let unpriced = ledger(storage: storage, rate: { _ in nil })
        #expect(unpriced.priced(unpriced.today).joules == 0)
        #expect(unpriced.priced(unpriced.today).unpricedGenerations == 1)
    }

    // MARK: - Days

    @Test("a new calendar day starts a fresh rollup and keeps yesterday")
    func dayRollover() {
        let clock = Clock(epoch)
        let ledger = ledger(storage: MemoryStorage(), clock: clock)
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100))
        clock.now = epoch.addingTimeInterval(day * 1.5)
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100))
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
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100))
        clock.now = epoch.addingTimeInterval(day)
        #expect(ledger.today.generations == 0)
        #expect(ledger.priced(ledger.today).joules == 0)
        #expect(ledger.today.day == utc.startOfDay(for: clock.now))
        #expect(ledger.days.count == 1)
    }

    @Test("history is capped at 30 days, oldest dropped")
    func thirtyDayCap() {
        let clock = Clock(epoch)
        let ledger = ledger(storage: MemoryStorage(), clock: clock)
        for offset in 0 ..< 31 {
            clock.now = epoch.addingTimeInterval(day * Double(offset))
            ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100))
        }
        #expect(ledger.days.count == EnergyLedger.historyCap)
        #expect(EnergyLedger.historyCap == 30)
        #expect(ledger.days.first?.day == utc.startOfDay(for: epoch.addingTimeInterval(day)))
    }

    @Test("a clock set back lands on its own day, in order, without disturbing the newest")
    func clockSetBack() {
        let clock = Clock(epoch.addingTimeInterval(day * 2))
        let ledger = ledger(storage: MemoryStorage(), clock: clock)
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100))
        clock.now = epoch
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100))
        #expect(ledger.days.map(\.day) == [utc.startOfDay(for: epoch), utc.startOfDay(for: epoch.addingTimeInterval(day * 2))])
    }

    // MARK: - Storage

    @Test("a fresh ledger reloads the persisted days")
    func reloads() {
        let storage = MemoryStorage()
        let first = ledger(storage: storage)
        first.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100))
        first.record(metrics: metrics(prompt: 100, decode: 10, model: nil))
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
        ledger.record(metrics: metrics(prompt: 100, decode: 10, prefilled: 100))
        let blob = try #require(storage.values[EnergyLedger.daysKey] as? Data)
        #expect(try JSONDecoder().decode([DailyEnergyRollup].self, from: blob).count == 1)
    }

    @Test("suppressed (the screengrab harness) records and writes nothing: priced, unpriced or unattributed")
    func suppressedWritesNothing() {
        let storage = MemoryStorage()
        let lilOnly = rate
        let ledger = ledger(storage: storage, rate: { $0 == .lil ? lilOnly : nil }, suppressed: true)
        #expect(ledger.record(metrics: metrics(prompt: 100, decode: 10)) == nil)
        #expect(ledger.record(metrics: metrics(prompt: 100, decode: 10, model: BrainTier.big.mlxModelID)) == nil)
        #expect(ledger.record(metrics: metrics(prompt: 100, decode: 10, model: nil)) == nil)
        #expect(storage.values.isEmpty)
        #expect(ledger.today.generations == 0)
        #expect(ledger.days.isEmpty)
    }

    // MARK: - The shell's wiring (read off the source: the app target does not build under swift test)

    @Test("the Mac shell feeds the ledger from the metrics sink, by the metrics' own model, never under screengrab")
    func shellWiring() throws {
        let env = try String(
            contentsOf: Self.packageRoot().appending(path: "M1K3App/AppEnvironment.swift"), encoding: .utf8
        )
        let declaration = try #require(env.range(of: "let energyLedger = EnergyLedger("))
        let arguments = String(env[declaration.upperBound...].prefix(160))
        #expect(arguments.contains("storage: UserDefaults.standard"))
        #expect(
            arguments.contains("suppressed: { ScreengrabHarness.current.isActive }"),
            "the harness reroutes stores but not UserDefaults.standard: a plate run must not write energy.days"
        )

        let sink = try #require(env.range(of: "func installGenerationMetricsSink()"))
        let tail = env[sink.upperBound...]
        let end = try #require(tail.range(of: "\n    }\n"))
        let body = String(tail[..<end.lowerBound])
        #expect(body.contains("energyLedger.record(metrics: metrics)"), "the ledger's only production feed")
        #expect(
            !body.contains("selectedBrain"),
            "billed by the model that generated, never by the picker: a deep dive serves Big with Lil selected"
        )
    }

    private static func packageRoot() throws -> URL {
        var root = URL(filePath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root = root.deletingLastPathComponent()
            try #require(root.path != "/", "no Package.swift above \(#filePath)")
        }
        return root
    }

    // MARK: - Privacy pin

    @Test("PRIVACY PIN: no ledger field can hold message text — exact keys, numeric leaves, no String in the types")
    func privacyPin() throws {
        let ledger = ledger(storage: MemoryStorage())
        let turn = try #require(ledger.record(metrics: metrics(prompt: 10, decode: 20)))
        ledger.record(metrics: metrics(prompt: 1, decode: 1, model: BrainTier.big.mlxModelID))
        ledger.record(metrics: metrics(prompt: 1, decode: 1, model: "mlx-community/Some-Audition-4bit"))
        let rollup = ledger.today

        #expect(try jsonKeys(turn) == ["tier", "prefillTokens", "decodeTokens", "joules", "measured"])
        #expect(try jsonKeys(rollup) == ["day", "unattributedGenerations", "perTier"])
        #expect(try jsonKeys(rollup.perTier[0]) == ["tier", "generations", "prefillTokens", "decodeTokens"])

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
            perTier: [.init(tier: .lil, generations: 1, prefillTokens: 1, decodeTokens: 1)]
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
