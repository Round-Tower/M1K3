//
//  OnboardingKit.swift
//  M1K3Inference
//
//  The onboarding deck's "My full kit" card as pure selection logic. The catalogue already knows
//  what this Mac can run and what is installed (`DownloadItem`); the kit decides which of those
//  to put on the card, what is ticked, what the total is, and how the rows read once the tap has
//  started them:
//    · brain row: Lil if it is not here, else Big where the catalogue offers it (16 GB floor).
//      Big starts UNticked (a 6.7 GB extra is a choice, not part of "my kit"); the rest are ticked.
//      The pocket Mini is not a kit row (the first-run fallback owns it).
//    · Semantic memory (EmbeddingGemma 2): only when a brain is ticked or already here,
//      via `SemanticMemoryOffer`; pre-ticked when shown; never for a Mini-only Mac.
//    · Sharper ears and M1K3 Voice, while absent.
//  After the tap `markStarted` pins those rows to the card so their STATIC status (Downloading…,
//  Ready, failed) stays visible. The live bar is `progress(items:)`, rendered outside the glass.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8 (pure rows over the real catalogue,
//  pinned by OnboardingKitTests; the card and the downloads are verify-by-launch). Prior: none (new file).

import Foundation

public struct OnboardingKit: Equatable, Sendable {
    /// What a row reads as. Static copy only inside the glass; the bar lives outside it.
    public enum Status: Equatable, Sendable {
        /// Not started: a checkbox row.
        case offer
        case downloading
        /// On disk and finishing (compiling, re-indexing): no honest fraction.
        case preparing
        case ready
        case failed(String)
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let item: DownloadItem
        public let ticked: Bool
        public let status: Status

        public var id: String {
            item.id
        }
    }

    /// Progress across the rows the tap started, for the fixed slot under the glass.
    public struct Progress: Equatable, Sendable {
        /// Byte-weighted, or nil while no started row has a real fraction (an honest spinner).
        public let fraction: Double?
        public let ready: Int
        public let total: Int
        /// Every started row is settled (ready or failed): the bar must stop.
        public let isFinished: Bool
    }

    private var choices: [DownloadKind: Bool] = [:]
    private var started: Set<DownloadKind> = []

    public init() {}

    /// Kit order: the brain, its memory, then the ears and the voice.
    private static let order: [DownloadKind] = [.lil, .big, .semanticMemory, .sharperEars, .voice]

    // MARK: - Ticks

    public func isTicked(_ kind: DownloadKind) -> Bool {
        choices[kind] ?? (kind != .big)
    }

    public mutating func toggle(_ kind: DownloadKind) {
        choices[kind] = !isTicked(kind)
    }

    public mutating func markStarted(_ kinds: [DownloadKind]) {
        started.formUnion(kinds)
    }

    // MARK: - Rows

    public func rows(items: [DownloadItem]) -> [Row] {
        let byKind = Dictionary(items.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = shownKinds(byKind)
        return Self.order.compactMap { kind in
            guard shown.contains(kind), let item = byKind[kind] else { return nil }
            let status = started.contains(kind) ? Self.startedStatus(item.state) : .offer
            return Row(item: item, ticked: isTicked(kind), status: status)
        }
    }

    /// Everything a fresh tap would start, in kit order.
    public func startList(items: [DownloadItem]) -> [DownloadKind] {
        rows(items: items).filter { $0.status == .offer && $0.ticked }.map(\.item.kind)
    }

    public func totalBytes(items: [DownloadItem]) -> Int64 {
        let list = Set(startList(items: items))
        return items.filter { list.contains($0.kind) }.reduce(0) { $0 + $1.bytes }
    }

    public func totalIsApproximate(items: [DownloadItem]) -> Bool {
        let list = Set(startList(items: items))
        return items.contains { list.contains($0.kind) && $0.sizeIsApproximate }
    }

    /// The first disk scan has not landed: say "looking", never "nothing to get".
    public func isChecking(items: [DownloadItem]) -> Bool {
        items.contains { $0.state == .checking }
    }

    /// Scanned, and everything this Mac could be offered is already here.
    public func hasNothingToOffer(items: [DownloadItem]) -> Bool {
        !isChecking(items: items) && rows(items: items).isEmpty
    }

    // MARK: - Copy

    /// One short line per kit item (the catalogue's `purpose` is Settings-length; the card is not).
    public static func shortPurpose(_ kind: DownloadKind) -> String {
        switch kind {
        case .lil: String(localized: "My everyday brain: quick, and it sees pictures.")
        case .big: String(localized: "The deep thinker: slower, sharper.")
        case .pocket: String(localized: "A small brain for this Mac.")
        case .semanticMemory: String(localized: "Finds your notes by meaning. Re-indexes them once.")
        case .sharperEars: String(localized: "Better dictation than Apple Speech.")
        case .voice: String(localized: "My own voice, instead of the built-in one.")
        }
    }

    /// The static line a started row shows inside the glass (the bar is outside it).
    public static func statusLine(_ status: Status) -> String? {
        switch status {
        case .offer: nil
        case .downloading: String(localized: "Downloading…")
        case .preparing: String(localized: "Getting it ready…")
        case .ready: String(localized: "Ready")
        case .failed: String(localized: "Couldn't download — try again from Settings ▸ Brains & downloads")
        }
    }

    // MARK: - Progress

    public func progress(items: [DownloadItem]) -> Progress {
        let begun = rows(items: items).filter { started.contains($0.item.kind) }
        var ready = 0
        var weight = 0.0
        var done = 0.0
        var anyKnown = false
        var settled = 0
        for row in begun {
            let bytes = Double(max(row.item.bytes, 1))
            weight += bytes
            switch row.status {
            case .ready:
                ready += 1
                settled += 1
                done += bytes
                anyKnown = true
            case .failed:
                settled += 1
            case .downloading:
                if case let .downloading(fraction?) = row.item.state {
                    done += bytes * min(max(fraction, 0), 1)
                    anyKnown = true
                }
            case .preparing, .offer:
                break
            }
        }
        let fraction: Double? = anyKnown && weight > 0 ? done / weight : nil
        return Progress(fraction: fraction, ready: ready, total: begun.count, isFinished: !begun.isEmpty && settled == begun.count)
    }

    // MARK: - Selection

    private static func needsDownload(_ state: DownloadState) -> Bool {
        switch state {
        case .absent, .partial, .failed: true
        default: false
        }
    }

    private static func isHere(_ state: DownloadState) -> Bool {
        state == .ready || state == .inUse
    }

    private static func isOnItsWay(_ state: DownloadState) -> Bool {
        switch state {
        case .downloading, .preparing: true
        default: false
        }
    }

    private static func startedStatus(_ state: DownloadState) -> Status {
        switch state {
        case .ready, .inUse: .ready
        case let .failed(message): .failed(message)
        case .preparing, .reindexing, .removing, .checking: .preparing
        case .downloading, .absent, .partial: .downloading
        }
    }

    /// The set of kinds on the card: whatever the tap started, plus what is on offer now.
    private func shownKinds(_ byKind: [DownloadKind: DownloadItem]) -> Set<DownloadKind> {
        var shown = started.intersection(byKind.keys)
        let brain = brainOffer(byKind)
        if let brain { shown.insert(brain) }

        if let memory = byKind[.semanticMemory], !started.contains(.semanticMemory),
           Self.needsDownload(memory.state)
        {
            // A brain in play: the one on the card if ticked, else one that is already here or coming.
            let target: BrainTier? = {
                if let brain, isTicked(brain) { return brain.brainTier }
                return [DownloadKind.lil, .big].first { kind in
                    byKind[kind].map { Self.isHere($0.state) || Self.isOnItsWay($0.state) } ?? false
                }?.brainTier
            }()
            if SemanticMemoryOffer.shouldOffer(
                brainTarget: target, usingMLXEmbeddings: memory.state == .inUse, installed: memory.state == .ready
            ) { shown.insert(.semanticMemory) }
        }
        for kind in [DownloadKind.sharperEars, .voice] {
            if let item = byKind[kind], Self.needsDownload(item.state) { shown.insert(kind) }
        }
        return shown
    }

    /// Lil if it is not here; else Big where the Mac offers it and Lil is settled on disk.
    private func brainOffer(_ byKind: [DownloadKind: DownloadItem]) -> DownloadKind? {
        if let lil = byKind[.lil] {
            if Self.needsDownload(lil.state) { return .lil }
            if started.contains(.lil) || !Self.isHere(lil.state) { return nil }
        }
        if let big = byKind[.big], !started.contains(.big), Self.needsDownload(big.state) { return .big }
        return nil
    }
}
