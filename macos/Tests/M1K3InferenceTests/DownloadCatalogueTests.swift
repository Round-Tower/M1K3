//
//  DownloadCatalogueTests.swift
//  M1K3InferenceTests
//
//  The pure half of Settings > Brains & downloads: which downloadables a Mac is
//  offered, what each one is called, how big it is, what state it reads as, and
//  which actions it allows. No disk, no network, no MLX.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8 (pure table; the pane
//  and the downloads behind it are verify-by-launch). Prior: none (new file).

@testable import M1K3Inference
import Testing

struct DownloadCatalogueTests {
    private static let sizes = DownloadSizes(
        bytes: [.lil: 3_068_000_000, .big: 6_740_000_000, .pocket: 663_000_000,
                .semanticMemory: 1_270_000_000, .sharperEars: 480_000_000, .voice: 191_000_000],
        approximate: [.sharperEars, .voice]
    )

    private static func items(
        ramGB: Double = 32, afm: AFMAvailability = .available,
        facts: [DownloadKind: DownloadFacts] = [:], whisper: String = "Small"
    ) -> [DownloadItem] {
        DownloadCatalogue.items(
            context: .init(physicalMemoryGB: ramGB, afm: afm, whisperVariantName: whisper),
            sizes: sizes, facts: facts
        )
    }

    private static func item(_ kind: DownloadKind, in items: [DownloadItem]) -> DownloadItem? {
        items.first { $0.kind == kind }
    }

    // MARK: - Which items appear

    @Test("a 32 GB Mac with Apple Intelligence sees five items, no pocket Mini, in the agreed order")
    func capableMac() {
        let kinds = Self.items().map(\.kind)
        #expect(kinds == [.lil, .big, .semanticMemory, .sharperEars, .voice])
    }

    @Test("pocket Mini appears only where Apple Intelligence is blocked, for either reason")
    func pocketNeedsBlockedAFM() {
        #expect(!Self.items(afm: .notReady).map(\.kind).contains(.pocket))
        #expect(Self.items(afm: .blocked(userFixable: true)).map(\.kind).contains(.pocket))
        #expect(Self.items(afm: .blocked(userFixable: false)).map(\.kind).contains(.pocket))
    }

    @Test("Big is offered only at the 16 GB floor")
    func bigNeedsFloor() {
        let floor = BrainTier.big.minimumPhysicalMemoryGB ?? 0
        #expect(floor > 0, "Big lost its RAM floor — this test must follow the new rule")
        #expect(!Self.items(ramGB: floor - 1).map(\.kind).contains(.big))
        #expect(Self.items(ramGB: floor).map(\.kind).contains(.big))
    }

    @Test("every item has a stable id, a name, a purpose and a size")
    func everyItemIsComplete() {
        let all = Self.items(afm: .blocked(userFixable: false))
        #expect(all.count == DownloadKind.allCases.count)
        #expect(Set(all.map(\.id)).count == all.count)
        for item in all {
            #expect(!item.name.isEmpty && !item.purpose.isEmpty)
            #expect(item.bytes > 0)
        }
        #expect(Self.item(.lil, in: all)?.id == "lil")
    }

    @Test("sizes come from the supplied table; brains without an entry fall back to the tier's estimate")
    func sizesAndFallback() {
        let all = Self.items()
        #expect(Self.item(.lil, in: all)?.bytes == 3_068_000_000)
        #expect(Self.item(.lil, in: all)?.sizeIsApproximate == false)
        #expect(Self.item(.voice, in: all)?.sizeIsApproximate == true)
        let bare = DownloadCatalogue.items(
            context: .init(physicalMemoryGB: 32, afm: .available, whisperVariantName: "Small"),
            sizes: DownloadSizes(bytes: [:], approximate: []), facts: [:]
        )
        #expect(Self.item(.lil, in: bare)?.bytes == Int64(BrainTier.lil.approxDownloadMB ?? 0) * 1_000_000)
        #expect(Self.item(.lil, in: bare)?.sizeIsApproximate == true)
    }

    @Test("Sharper ears names the chosen WhisperKit variant")
    func whisperVariantNamed() {
        let ears = Self.item(.sharperEars, in: Self.items(whisper: "Base"))
        #expect(ears?.purpose.contains("Base") == true)
    }

    // MARK: - State mapping

    @Test("nothing on disk and no load reads as absent, with Download the only action")
    func absent() {
        let lil = Self.item(.lil, in: Self.items())
        #expect(lil?.state == .absent)
        #expect(lil?.actions == [.download])
    }

    @Test("ModelLoadState maps onto download state: downloading, preparing, failed")
    func loadStateMapping() {
        func state(_ load: ModelLoadState, installed: Bool = false, inUse: Bool = false) -> DownloadState {
            DownloadState.resolve(.init(installed: installed, load: load, inUse: inUse))
        }
        #expect(state(.progress(0.4)) == .downloading(fraction: 0.4))
        #expect(state(.preparing) == .preparing)
        #expect(state(.failed(message: "no")) == .failed("no"))
        #expect(state(.idle, installed: true) == .ready)
        #expect(state(.ready, installed: true) == .ready)
        #expect(state(.idle, installed: true, inUse: true) == .inUse)
        #expect(state(.idle) == .absent)
    }

    @Test("a load in flight wins over what is on disk; a failure on an in-use item does not hide it")
    func precedence() {
        #expect(DownloadState.resolve(.init(installed: true, load: .progress(0.5), inUse: true))
            == .downloading(fraction: 0.5))
        #expect(DownloadState.resolve(.init(installed: true, load: .failed(message: "x"), inUse: true)) == .inUse)
        #expect(DownloadState.resolve(.init(installed: false, load: .failed(message: "x"), inUse: false)) == .failed("x"))
    }

    // MARK: - Actions

    @Test("cancel is offered for brains and the voice, not for the embedder or WhisperKit")
    func cancelCoverage() {
        let downloading = DownloadFacts(installed: false, load: .progress(0.2), inUse: false)
        let facts = Dictionary(uniqueKeysWithValues: DownloadKind.allCases.map { ($0, downloading) })
        let all = Self.items(afm: .blocked(userFixable: false), facts: facts)
        for kind in [DownloadKind.lil, .big, .pocket, .voice] {
            #expect(Self.item(kind, in: all)?.actions == [.cancel], "\(kind)")
        }
        for kind in [DownloadKind.semanticMemory, .sharperEars] {
            #expect(Self.item(kind, in: all)?.actions == [], "\(kind)")
        }
    }

    @Test("a foreground brain download shows progress but no Cancel (it cannot truly stop)")
    func foregroundDownloadHasNoCancel() {
        let lil = Self.item(.lil, in: Self.items(facts: [
            .lil: .init(installed: false, load: .progress(0.3), inUse: false, canCancel: false),
        ]))
        #expect(lil?.state == .downloading(fraction: 0.3))
        #expect(lil?.actions == [])
    }

    @Test("an unused download can be removed; a failed one can be retried")
    func removeAndRetry() {
        let all = Self.items(facts: [
            .big: .init(installed: true, load: .idle, inUse: false),
            .lil: .init(installed: false, load: .failed(message: "offline"), inUse: false),
        ])
        #expect(Self.item(.big, in: all)?.actions == [.remove])
        #expect(Self.item(.lil, in: all)?.actions == [.download])
    }

    @Test("in-use items are never removable: live brain, active embedder, voice and WhisperKit")
    func inUseProtected() {
        let facts = Dictionary(uniqueKeysWithValues: DownloadKind.allCases.map {
            ($0, DownloadFacts(installed: true, load: .ready, inUse: true))
        })
        for item in Self.items(afm: .blocked(userFixable: false), facts: facts) {
            #expect(item.state == .inUse, "\(item.kind)")
            #expect(!item.actions.contains(.remove), "\(item.kind) offered Remove while in use")
            #expect(item.actions.isEmpty, "\(item.kind)")
        }
    }
}
