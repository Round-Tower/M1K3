//
//  HeartbeatContext.swift
//  M1K3Heartbeat
//
//  The typed snapshot a pulse is composed from. Every field is gathered by
//  the app from EXISTING consent-clean sources (SystemStatusProviding,
//  MemoryStore.revision, ChatHistoryStore summaries, the opt-in MCP log,
//  brain state) — the pure module never reads the OS. Optional sections are
//  absent when their source is off or empty, and the composer renders only
//  what's present, so consent is structural: an off toggle means the field
//  never exists here.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.9 (pure data;
//  the consent-at-the-gather-site contract is enforced by the app wiring,
//  named there). Prior: none (new file).
//

import Foundation

/// Doctrine-principle-7 rendering of `ProcessInfo.thermalState`: the pure
/// module speaks in bands, the composer turns bands into plain words.
public enum ThermalBand: String, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
}

/// Everything one pulse may talk about. `Equatable` so composer determinism
/// is testable as byte equality of inputs.
public struct HeartbeatContext: Sendable, Equatable {
    public struct Device: Sendable, Equatable {
        /// nil on a desktop machine (no battery) — the composer omits the line.
        public var batteryPercent: Int?
        public var isCharging: Bool?
        public var diskFreeGB: Double?
        public var diskTotalGB: Double?
        public var uptimeHours: Double?
        public var thermal: ThermalBand
        public var lowPowerMode: Bool

        public init(
            batteryPercent: Int? = nil,
            isCharging: Bool? = nil,
            diskFreeGB: Double? = nil,
            diskTotalGB: Double? = nil,
            uptimeHours: Double? = nil,
            thermal: ThermalBand = .nominal,
            lowPowerMode: Bool = false
        ) {
            self.batteryPercent = batteryPercent
            self.isCharging = isCharging
            self.diskFreeGB = diskFreeGB
            self.diskTotalGB = diskTotalGB
            self.uptimeHours = uptimeHours
            self.thermal = thermal
            self.lowPowerMode = lowPowerMode
        }
    }

    /// Memory-graph movement since the last pulse: titles of newly learned
    /// facts (already user-visible in the Memories screen — no new exposure)
    /// plus how many facts were corrected (superseded).
    public struct MemoryActivity: Sendable, Equatable {
        public var newFactTitles: [String]
        public var supersededCount: Int

        public init(newFactTitles: [String], supersededCount: Int) {
            self.newFactTitles = newFactTitles
            self.supersededCount = supersededCount
        }
    }

    /// Conversations touched since the last pulse — titles only, never text.
    public struct ChatActivity: Sendable, Equatable {
        public var touchedConversationTitles: [String]

        public init(touchedConversationTitles: [String]) {
            self.touchedConversationTitles = touchedConversationTitles
        }
    }

    /// Inbound visiting-agent traffic — present ONLY when the Agent
    /// Interaction Log toggle is already on (its consent, not ours).
    public struct MCPActivity: Sendable, Equatable {
        public var callCount: Int
        public var topTools: [String]

        public init(callCount: Int, topTools: [String]) {
            self.callCount = callCount
            self.topTools = topTools
        }
    }

    public struct BrainStatus: Sendable, Equatable {
        public var residentTierName: String?
        /// What the tier IS, in apposition — "the larger brain". A bare "Big"
        /// in the digest reads as a housemate to a model that never heard the
        /// name (three live pulses kept it company on the shelf, 2026-08-30).
        public var residentTierDescriptor: String?
        public var downloadingModelName: String?

        public init(
            residentTierName: String? = nil,
            residentTierDescriptor: String? = nil,
            downloadingModelName: String? = nil
        ) {
            self.residentTierName = residentTierName
            self.residentTierDescriptor = residentTierDescriptor
            self.downloadingModelName = downloadingModelName
        }
    }

    /// One deterministic pick from M1K3's own corpus, with its source title —
    /// "something fun, something very M1K3", cited like everything else.
    public struct FunFact: Sendable, Equatable {
        public var text: String
        public var sourceTitle: String

        public init(text: String, sourceTitle: String) {
            self.text = text
            self.sourceTitle = sourceTitle
        }
    }

    public var date: Date
    public var device: Device
    public var memory: MemoryActivity?
    public var chat: ChatActivity?
    public var mcp: MCPActivity?
    public var brain: BrainStatus?
    public var funFact: FunFact?
    /// The day's earlier pulse texts, oldest first — the arc the next
    /// narrative continues.
    public var earlierPulsesToday: [String]

    public init(
        date: Date,
        device: Device,
        memory: MemoryActivity? = nil,
        chat: ChatActivity? = nil,
        mcp: MCPActivity? = nil,
        brain: BrainStatus? = nil,
        funFact: FunFact? = nil,
        earlierPulsesToday: [String] = []
    ) {
        self.date = date
        self.device = device
        self.memory = memory
        self.chat = chat
        self.mcp = mcp
        self.brain = brain
        self.funFact = funFact
        self.earlierPulsesToday = earlierPulsesToday
    }
}
