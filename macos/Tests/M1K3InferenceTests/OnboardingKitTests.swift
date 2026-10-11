//
//  OnboardingKitTests.swift
//  M1K3InferenceTests
//
//  The deck's "My full kit" card as pure selection logic: which downloads appear per Mac and
//  per installed state, what is pre-ticked, the total, and when semantic memory is offered
//  (only with a brain, ticked or already here).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure rows over the real catalogue;
//  the card, the downloads behind it and the glass-safe progress slot are verify-by-launch).
//  Prior: none (new file).

@testable import M1K3Inference
import Testing

struct OnboardingKitTests {
    private static let sizes = DownloadSizes(
        bytes: [.lil: 3_068_000_000, .big: 6_740_000_000, .pocket: 663_000_000,
                .semanticMemory: 1_270_000_000, .sharperEars: 480_000_000, .voice: 191_000_000],
        approximate: [.sharperEars, .voice]
    )

    private static func items(
        ramGB: Double = 32, afm: AFMAvailability = .available, facts: [DownloadKind: DownloadFacts] = [:]
    ) -> [DownloadItem] {
        DownloadCatalogue.items(
            context: .init(physicalMemoryGB: ramGB, afm: afm, whisperVariantName: "Small"),
            sizes: sizes, facts: facts
        )
    }

    private static let installed = DownloadFacts(installed: true)

    private static func kinds(_ kit: OnboardingKit, _ items: [DownloadItem]) -> [DownloadKind] {
        kit.rows(items: items).map(\.item.kind)
    }

    // MARK: - Which rows

    @Test("a fresh capable Mac sees Lil, semantic memory, ears and voice, all pre-ticked; Big is not offered beside Lil")
    func freshMac() {
        let items = Self.items()
        let kit = OnboardingKit()
        #expect(Self.kinds(kit, items) == [.lil, .semanticMemory, .sharperEars, .voice])
        #expect(kit.rows(items: items).allSatisfy { $0.ticked })
        #expect(kit.rows(items: items).allSatisfy { $0.status == .offer })
    }

    @Test("with Lil already here the brain row is Big, where the Mac offers it, and Big starts unticked")
    func bigWhenLilIsHere() {
        let items = Self.items(facts: [.lil: Self.installed])
        let kit = OnboardingKit()
        let rows = kit.rows(items: items)
        #expect(rows.map(\.item.kind) == [.big, .semanticMemory, .sharperEars, .voice])
        #expect(rows.first?.ticked == false)
        // Memory still appears: a brain is installed.
        #expect(rows.contains { $0.item.kind == .semanticMemory })
    }

    @Test("a 8 GB Mac with Lil here has no Big to offer; the brain row is simply absent")
    func smallMacWithLil() {
        let items = Self.items(ramGB: 8, facts: [.lil: Self.installed])
        #expect(Self.kinds(OnboardingKit(), items) == [.semanticMemory, .sharperEars, .voice])
    }

    @Test("semantic memory appears only with a brain: unticking Lil hides it, reticking restores the choice")
    func memoryNeedsABrain() {
        let items = Self.items()
        var kit = OnboardingKit()
        kit.toggle(.lil)
        #expect(Self.kinds(kit, items) == [.lil, .sharperEars, .voice])
        kit.toggle(.lil)
        #expect(Self.kinds(kit, items) == [.lil, .semanticMemory, .sharperEars, .voice])
    }

    @Test("with no brain to offer or hold, memory is never shown (Mini-only stays on Hashing)")
    func miniOnlyNeverSeesMemory() {
        // Lil and Big both hidden by the facts: pretend neither is offerable by marking Big absent
        // on a small Mac and Lil failed-to-install is still offered, so use a Mac whose Lil is
        // mid-download elsewhere (not a candidate) and Big is below the floor.
        let items = Self.items(ramGB: 8, facts: [.lil: DownloadFacts(load: .progress(0.4))])
        // Lil is downloading (so a brain is on its way) → memory IS offered…
        #expect(Self.kinds(OnboardingKit(), items).contains(.semanticMemory))
        // …but with Lil absent and unticked, no brain is in play at all.
        var kit = OnboardingKit()
        kit.toggle(.lil)
        let fresh = Self.items(ramGB: 8)
        #expect(!Self.kinds(kit, fresh).contains(.semanticMemory))
    }

    @Test("a Mac already on MLX embeddings, or with the embedder on disk, is not offered memory")
    func memoryAlreadyHad() {
        let using = Self.items(facts: [.semanticMemory: DownloadFacts(installed: true, inUse: true)])
        #expect(!Self.kinds(OnboardingKit(), using).contains(.semanticMemory))
        let onDisk = Self.items(facts: [.semanticMemory: Self.installed])
        #expect(!Self.kinds(OnboardingKit(), onDisk).contains(.semanticMemory))
    }

    @Test("everything installed: nothing to offer, and the card can say so")
    func everythingInstalled() {
        var facts: [DownloadKind: DownloadFacts] = [:]
        for kind in DownloadKind.allCases {
            facts[kind] = Self.installed
        }
        let items = Self.items(facts: facts)
        let kit = OnboardingKit()
        #expect(kit.rows(items: items).isEmpty)
        #expect(kit.hasNothingToOffer(items: items))
        #expect(kit.startList(items: items).isEmpty)
        #expect(kit.totalBytes(items: items) == 0)
    }

    @Test("before the first disk scan lands the card is checking, not empty")
    func checkingBeforeScan() {
        var facts: [DownloadKind: DownloadFacts] = [:]
        for kind in DownloadKind.allCases {
            facts[kind] = DownloadFacts(scanned: false)
        }
        let items = Self.items(facts: facts)
        let kit = OnboardingKit()
        #expect(kit.isChecking(items: items))
        #expect(!kit.hasNothingToOffer(items: items))
        #expect(kit.rows(items: items).isEmpty)
    }

    @Test("the pocket Mini on a Mac without Apple Intelligence is never a kit row")
    func pocketIsNotInTheKit() {
        let items = Self.items(afm: .blocked(userFixable: false))
        #expect(!Self.kinds(OnboardingKit(), items).contains(.pocket))
        #expect(Self.kinds(OnboardingKit(), items).contains(.lil))
    }

    // MARK: - Total + the start list

    @Test("the total sums the ticked offer rows; unticking drops its bytes; the start list follows the ticks")
    func totalAndStartList() {
        let items = Self.items()
        var kit = OnboardingKit()
        #expect(kit.totalBytes(items: items) == 3_068_000_000 + 1_270_000_000 + 480_000_000 + 191_000_000)
        #expect(kit.startList(items: items) == [.lil, .semanticMemory, .sharperEars, .voice])
        kit.toggle(.sharperEars)
        #expect(kit.totalBytes(items: items) == 3_068_000_000 + 1_270_000_000 + 191_000_000)
        #expect(kit.startList(items: items) == [.lil, .semanticMemory, .voice])
        kit.toggle(.lil) // memory goes with its brain, in the list and in the sum
        #expect(kit.startList(items: items) == [.voice])
        #expect(kit.totalBytes(items: items) == 191_000_000)
    }

    @Test("the total flags an estimate when any ticked row is approximate")
    func totalIsApproximate() {
        let items = Self.items()
        var kit = OnboardingKit()
        #expect(kit.totalIsApproximate(items: items)) // ears + voice are estimates
        kit.toggle(.sharperEars)
        kit.toggle(.voice)
        #expect(!kit.totalIsApproximate(items: items))
    }

    // MARK: - After the tap

    @Test("started rows stay on the card with a static status that follows the catalogue")
    func startedRowsKeepTheirStatus() {
        var kit = OnboardingKit()
        let before = Self.items()
        let list = kit.startList(items: before)
        kit.markStarted(list)

        let mid = Self.items(facts: [
            .lil: DownloadFacts(load: .progress(0.3)),
            .semanticMemory: DownloadFacts(installed: true),
            .sharperEars: DownloadFacts(load: .failed(message: "No connection")),
            .voice: DownloadFacts(load: .preparing),
        ])
        let rows = Dictionary(uniqueKeysWithValues: kit.rows(items: mid).map { ($0.item.kind, $0.status) })
        #expect(rows[.lil] == .downloading)
        #expect(rows[.semanticMemory] == .ready)
        #expect(rows[.sharperEars] == .failed("No connection"))
        #expect(rows[.voice] == .preparing)
        // A started row is no longer part of a fresh tap.
        #expect(kit.startList(items: mid).isEmpty)
        #expect(kit.totalBytes(items: mid) == 0)
    }

    @Test("a started row that the catalogue has not caught up on reads Downloading, never a dead Offer")
    func startedButNotYetReflected() {
        var kit = OnboardingKit()
        kit.markStarted([.sharperEars])
        let rows = kit.rows(items: Self.items())
        #expect(rows.first { $0.item.kind == .sharperEars }?.status == .downloading)
    }

    @Test("a started memory row stays visible even though its brain is now installed or unticked")
    func startedMemoryStays() {
        var kit = OnboardingKit()
        kit.markStarted([.lil, .semanticMemory])
        let items = Self.items(facts: [.lil: Self.installed, .semanticMemory: DownloadFacts(load: .progress(0.5))])
        #expect(Self.kinds(kit, items).contains(.semanticMemory))
    }

    // MARK: - Progress for the live slot

    @Test("kit progress is byte-weighted across started rows and counts the ready ones")
    func progress() {
        var kit = OnboardingKit()
        kit.markStarted([.sharperEars, .voice])
        let items = Self.items(facts: [
            .sharperEars: DownloadFacts(installed: true),
            .voice: DownloadFacts(load: .progress(0.5)),
        ])
        let progress = kit.progress(items: items)
        #expect(progress.total == 2)
        #expect(progress.ready == 1)
        // (480 * 1 + 191 * 0.5) / (480 + 191)
        let expected = (480.0 + 95.5) / 671.0
        #expect(abs((progress.fraction ?? -1) - expected) < 1e-9)
        #expect(!progress.isFinished)
    }

    @Test("progress is indeterminate while no started row has a fraction, and finished when none is active")
    func progressEdges() {
        var kit = OnboardingKit()
        kit.markStarted([.voice])
        let preparing = kit.progress(items: Self.items(facts: [.voice: DownloadFacts(load: .preparing)]))
        #expect(preparing.fraction == nil)
        #expect(!preparing.isFinished)
        let done = kit.progress(items: Self.items(facts: [.voice: Self.installed]))
        #expect(done.isFinished)
        let failed = kit.progress(items: Self.items(facts: [.voice: DownloadFacts(load: .failed(message: "x"))]))
        #expect(failed.isFinished, "a failed item is settled: the bar must not spin forever")
        #expect(OnboardingKit().progress(items: Self.items()).total == 0)
    }

    @Test("every kit item has a one-line purpose, and a started row has static status copy (the failure names Settings)")
    func copy() {
        for kind in DownloadKind.allCases {
            #expect(!OnboardingKit.shortPurpose(kind).isEmpty)
        }
        #expect(OnboardingKit.statusLine(.offer) == nil)
        #expect(OnboardingKit.statusLine(.downloading) == "Downloading…")
        #expect(OnboardingKit.statusLine(.ready) == "Ready")
        #expect(OnboardingKit.statusLine(.failed("x")) == "Couldn't download — try again from Settings ▸ Brains & downloads")
    }

    @Test("the deck without a wait carries the kit card; the wait decks do not")
    func deckMembership() {
        #expect(WakeSetupCard.allCases.contains(.kit))
        #expect(!WakeSetupCard.waitDeck.contains(.kit))
        #expect(WakeSetupCard.waitDeck == WakeSetupCard.allCases.filter { $0 != .kit })
        #expect(WakeSetupCard.allCases.last == .kit, "the kit closes the deck: the last thing before Done")
    }
}
