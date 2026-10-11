//
//  DownloadCatalogue.swift
//  M1K3Inference
//
//  Everything M1K3 can download, in one pure table: Lil, Big, the pocket Mini, Semantic
//  memory, Sharper ears and M1K3 Voice. Each carries a plain name and purpose, an exact
//  size where the build pins one, a state, and the actions that state allows. Settings >
//  Brains & downloads renders it; AppEnvironment+Downloads feeds it the facts.
//
//  Why it lives in M1K3Inference: it is built from `BrainTier` (RAM floor, estimates),
//  `AFMAvailability` and `ModelLoadState`, all of which already live here, and it must
//  stay Metal-free so `swift test` drives it. The size sources sit in LATER modules
//  (`PinnedWeights` in M1K3MLX, `WhisperModelVariant`, the Kokoro pins), so sizes arrive
//  as a `DownloadSizes` value the shell assembles (`DownloadSizes.manifest(...)` in
//  M1K3MLX does the pinned half) rather than being imported backwards.
//
//  In-use protection is the caller's `DownloadFacts.inUse`, assembled from the same
//  sources as `RetiredWeightsPolicy`'s keep-set (the live brain, the active embedder,
//  the selected voice, the loaded WhisperKit model): an in-use item has NO actions.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8 (pure table pinned by
//  DownloadCatalogueTests; the copy is first-draft M1K3 voice). Prior: none (new file).

import Foundation

public enum DownloadKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case lil, big, pocket, semanticMemory, sharperEars, voice

    public var id: String {
        rawValue
    }

    /// The brain tier behind this item, for the three brain downloads.
    public var brainTier: BrainTier? {
        switch self {
        case .lil: .lil
        case .big: .big
        case .pocket: .pocket
        case .semanticMemory, .sharperEars, .voice: nil
        }
    }

    /// Whether an in-flight download can truly be stopped. Brains go through the
    /// cancellable fetcher and the voice has its own task; the embedder and WhisperKit
    /// are opaque single calls (follow-up), so they show progress but no Cancel.
    public var supportsCancel: Bool {
        switch self {
        case .lil, .big, .pocket, .voice: true
        case .semanticMemory, .sharperEars: false
        }
    }
}

/// What the shell knows about one item right now.
public struct DownloadFacts: Equatable, Sendable {
    public var installed: Bool
    public var load: ModelLoadState
    public var inUse: Bool
    /// Whether the load in flight can truly be stopped. A brain fetched through the
    /// manager (or the background upgrade) can; the foreground `selectBrain` download
    /// cannot (`SingleFlightLoader` keeps the load alive for its other waiters), so its
    /// row shows progress and no Cancel rather than a button that lies.
    public var canCancel: Bool

    public init(
        installed: Bool = false, load: ModelLoadState = .idle, inUse: Bool = false, canCancel: Bool = true
    ) {
        self.installed = installed
        self.load = load
        self.inUse = inUse
        self.canCancel = canCancel
    }
}

public enum DownloadState: Equatable, Sendable {
    case absent
    /// `fraction == nil` is an honest indeterminate spinner, never a stuck bar.
    case downloading(fraction: Double?)
    /// On disk and finishing up (compiling, re-indexing): no honest fraction.
    case preparing
    case ready
    case failed(String)
    /// On disk AND serving right now. Never removable.
    case inUse

    /// A load in flight wins over what is on disk; a failure never hides an item that is
    /// serving fine; otherwise disk and use decide.
    public static func resolve(_ facts: DownloadFacts) -> DownloadState {
        switch facts.load {
        case let .downloading(fraction): return .downloading(fraction: fraction)
        case .preparing: return .preparing
        case let .failed(message):
            return facts.installed && facts.inUse ? .inUse : .failed(message)
        case .idle, .ready:
            if facts.installed { return facts.inUse ? .inUse : .ready }
            return .absent
        }
    }
}

public struct DownloadActions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let download = DownloadActions(rawValue: 1 << 0)
    public static let cancel = DownloadActions(rawValue: 1 << 1)
    public static let remove = DownloadActions(rawValue: 1 << 2)
}

public struct DownloadItem: Identifiable, Equatable, Sendable {
    public let kind: DownloadKind
    public let name: String
    public let purpose: String
    public let bytes: Int64
    /// True when `bytes` is an estimate (an unpinned file, or a tier's rough figure).
    public let sizeIsApproximate: Bool
    public let state: DownloadState
    public let actions: DownloadActions

    public var id: String {
        kind.id
    }
}

/// Byte sizes per item. Assembled by the shell; `approximate` names the ones that are
/// estimates rather than pinned bytes.
public struct DownloadSizes: Equatable, Sendable {
    public var bytes: [DownloadKind: Int64]
    public var approximate: Set<DownloadKind>

    public init(bytes: [DownloadKind: Int64], approximate: Set<DownloadKind>) {
        self.bytes = bytes
        self.approximate = approximate
    }
}

public enum DownloadCatalogue {
    /// What the Mac can run: decides which items are offered at all.
    public struct Context: Equatable, Sendable {
        public var physicalMemoryGB: Double
        public var afm: AFMAvailability
        /// The chosen WhisperKit accuracy tier's display name ("Small").
        public var whisperVariantName: String

        public init(physicalMemoryGB: Double, afm: AFMAvailability, whisperVariantName: String) {
            self.physicalMemoryGB = physicalMemoryGB
            self.afm = afm
            self.whisperVariantName = whisperVariantName
        }
    }

    public static func items(
        context: Context, sizes: DownloadSizes, facts: [DownloadKind: DownloadFacts]
    ) -> [DownloadItem] {
        DownloadKind.allCases.compactMap { kind in
            guard isOffered(kind, on: context) else { return nil }
            let fact = facts[kind] ?? DownloadFacts()
            let state = DownloadState.resolve(fact)
            let (bytes, approximate) = size(of: kind, in: sizes)
            return DownloadItem(
                kind: kind, name: name(of: kind), purpose: purpose(of: kind, context: context),
                bytes: bytes, sizeIsApproximate: approximate,
                state: state, actions: actions(for: kind, in: state, canCancel: fact.canCancel)
            )
        }
    }

    static func isOffered(_ kind: DownloadKind, on context: Context) -> Bool {
        switch kind {
        case .lil, .semanticMemory, .sharperEars, .voice: true
        case .big: BrainTier.big.isSelectable(forPhysicalMemoryGB: context.physicalMemoryGB)
        case .pocket: context.afm.isBlocked
        }
    }

    static func actions(for kind: DownloadKind, in state: DownloadState, canCancel: Bool) -> DownloadActions {
        switch state {
        case .absent, .failed: [.download]
        case .downloading: kind.supportsCancel && canCancel ? [.cancel] : []
        case .preparing, .inUse: []
        case .ready: [.remove]
        }
    }

    private static func size(of kind: DownloadKind, in sizes: DownloadSizes) -> (Int64, Bool) {
        if let exact = sizes.bytes[kind] { return (exact, sizes.approximate.contains(kind)) }
        if let megabytes = kind.brainTier?.approxDownloadMB { return (Int64(megabytes) * 1_000_000, true) }
        return (0, true)
    }

    private static func name(of kind: DownloadKind) -> String {
        switch kind {
        case .lil: String(localized: "Lil")
        case .big: String(localized: "Big")
        case .pocket: String(localized: "Mini")
        case .semanticMemory: String(localized: "Semantic memory")
        case .sharperEars: String(localized: "Sharper ears")
        case .voice: String(localized: "M1K3 Voice")
        }
    }

    private static func purpose(of kind: DownloadKind, context: Context) -> String {
        switch kind {
        case .lil: String(localized: "My everyday brain. Quick, sees pictures, lives on this Mac.")
        case .big: String(localized: "The deep thinker. Slower, sharper, for the hard questions.")
        case .pocket: String(localized: "A small brain for this Mac, which can't run Apple Intelligence.")
        case .semanticMemory: String(localized: "Finds your notes by meaning, not just matching words.")
        case .sharperEars:
            String(localized: "Better dictation than Apple Speech (WhisperKit \(context.whisperVariantName)).")
        case .voice: String(localized: "My own voice, instead of the built-in one.")
        }
    }
}
