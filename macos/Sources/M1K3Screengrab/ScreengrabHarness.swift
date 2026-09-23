//
//  ScreengrabHarness.swift
//  M1K3Screengrab
//
//  The launch-time switch both shells read (M1K3_SCREENGRAB=1). Active, it
//  moves every store to a SIBLING data root (`M1K3-screengrab` beside `M1K3`
//  in Application Support — inside the sandbox container, so the sandboxed
//  app can write it), seeds the demo persona there, and answers the per-plate
//  questions the shells ask (enter voice mode? speak the hero answer? show
//  pairing?). Inert for every ordinary launch: no env, no behaviour change.
//
//  Why a sibling root and not a wipe: Kev's live memories are the one thing
//  that must never appear in a store frame (#225), and a capture run that
//  deleted them to get a clean slate would be worse than the placeholder.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.9 (pure; root
//  isolation + plate flags pinned), Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-08 — `livePartial`: the listening plate's
//  hero question through the open mic. Confidence now 0.9.
//  Review: Kev + claude-fable-5.1, 2026-09-09 — `hidesViewfinder` for the iOS pairing plate. Confidence now 0.9.
//

import Foundation

public struct ScreengrabHarness: Sendable, Equatable {
    public static let activeKey = "M1K3_SCREENGRAB"
    public static let plateKey = "M1K3_SCREENGRAB_PLATE"
    /// The sibling directory name beside the live `M1K3` data root.
    public static let dataRootName = "M1K3-screengrab"
    /// One token per capture run (capture.sh stamps it): the first launch that
    /// sees a new token starts from an empty sibling root.
    public static let runKey = "M1K3_SCREENGRAB_RUN"
    /// The file inside the sibling root that remembers which run it belongs to.
    public static let runStampName = ".screengrab-run"

    /// The process-wide read; the shells consult this at init.
    public static let current = ScreengrabHarness(environment: ProcessInfo.processInfo.environment)

    public let isActive: Bool
    public let plate: ScreengrabPlate?
    /// The capture run this launch belongs to; nil outside a capture run.
    public let runToken: String?

    public init(environment: [String: String]) {
        isActive = environment[Self.activeKey] == "1"
        plate = isActive ? environment[Self.plateKey].flatMap(ScreengrabPlate.init(rawValue:)) : nil
        runToken = isActive ? environment[Self.runKey].flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    /// Where the stores live for this launch: the live root when inactive, the
    /// sibling screengrab root when active.
    public func dataRoot(live: URL) -> URL {
        guard isActive else { return live }
        return live.deletingLastPathComponent()
            .appendingPathComponent(Self.dataRootName, isDirectory: true)
    }

    /// Empties the sibling root once per capture run, before any store opens.
    /// A shell can't clear another app's container under macOS app-data privacy,
    /// so a stale seed marker used to survive every run (the constellation plate
    /// kept five motes after #383 seeded thirty-nine). The app clears its OWN
    /// root: when the run token differs from the one stamped inside it. Returns
    /// whether it cleared. Never touches `live`.
    @discardableResult
    public func prepareRoot(live: URL, fileManager: FileManager = .default) throws -> Bool {
        guard isActive, let runToken else { return false }
        let root = dataRoot(live: live)
        let stamp = root.appendingPathComponent(Self.runStampName)
        if let existing = try? String(contentsOf: stamp, encoding: .utf8), existing == runToken {
            return false
        }
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(runToken.utf8).write(to: stamp)
        return true
    }

    // MARK: - Per-plate questions the shells ask

    public var showsOnboarding: Bool {
        plate == .onboarding
    }

    /// Voice plates AND the companion tiles: voice mode is the full-window
    /// avatar surface the plan asks for ("same framing, creature centred").
    public var entersVoiceMode: Bool {
        guard let plate else { return false }
        return plate == .voiceListening || plate == .voiceSpeaking || plate.companionID != nil
    }

    /// The speaking plate is a REAL turn: the open mic submits the hero question
    /// (a final segment), the loop answers from the seeded knowledge and speaks
    /// it with the karaoke line. A direct `speak` never moves the loop into
    /// `.speaking`, so it never showed the line (runs 3 + 4).
    public var submitsHeroQuestion: Bool {
        plate == .voiceSpeaking
    }

    /// The voice plates' live partial: the hero question arriving word by word
    /// through `OpenMicTranscriber` (listening: the frame shows a real listen;
    /// speaking: the question that is then submitted). Nil for a companion tile
    /// — that plate is the face, not a bubble.
    public var livePartial: String? {
        switch plate {
        case .voiceSpeaking: DemoPersona.heroConversation[0].text
        case .voiceListening: DemoPersona.listeningDictation
        default: nil
        }
    }

    public var showsPairing: Bool {
        plate == .brainAtHome
    }

    /// iOS: the pairing screen mounts no viewfinder (and asks no camera
    /// permission) — the system's TCC alert sat in the plate (2026-09-09,
    /// phone run 1), and a real camera feed of the desk is no App Store frame.
    /// The plate shows the instructions and the paste path.
    public var hidesViewfinder: Bool {
        showsPairing
    }

    /// Mac: the sidebar room ContentView opens on instead of chat.
    public var showsDocuments: Bool {
        plate == .documents
    }

    public var showsMemories: Bool {
        plate == .memories
    }

    /// Mac: the Settings scene is the subject. Pairing (Brain at Home) AND the
    /// privacy stand-in both live in Settings ▸ Privacy.
    public var opensSettings: Bool {
        plate == .brainAtHome || plate == .privacyLabel
    }

    public var showsPrivacyPane: Bool {
        plate == .privacyLabel || plate == .brainAtHome
    }
}
