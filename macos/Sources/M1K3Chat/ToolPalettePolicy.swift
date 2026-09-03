//
//  ToolPalettePolicy.swift
//  M1K3Chat
//
//  Dynamic tool calling on what's available. A tool is offered to the model only
//  while the thing it does is actually there: a corpus to search, a web the
//  toggle allows (a page RENDER reaches the internet too, so open_link rides the
//  same toggle), a bigger brain the dive would really reach, a battery to read.
//  Kev's ask after the first phone-vs-Mac voice session (2026-09-03): the phone
//  felt more present partly because its palette was leaner; the Mac's should be
//  lean by the same rule, and both shells should derive their palette from ONE
//  rule instead of two hand-tuned lists.
//
//  The inputs are deliberately STABLE facts — they change on a toggle, a download,
//  a first document — never per turn or per query. The palette is a
//  PersonaPrefixCache key: a different tool set is a ~6 s cold prefix rebuild
//  (ROADMAP: "tune the grounding, never the palette"). So this is availability
//  gating, NOT per-question routing; the latter would thrash the 2-entry cache
//  and is a separate, measured decision.
//
//  Names are strings for the same reason SelfQueryGate's are: M1K3Chat cannot
//  link the tool modules (tools are injected by the app layer). The
//  `namesMatchLiveTools` pin in ToolPalettePolicyTests guards them against drift.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-03, Confidence 0.85 (pure policy,
//  pinned; the app-side facts feeding Availability are each read from the
//  same seam the feature itself uses — DeepDiveTarget.plan for the dive,
//  the web toggle for the web, LocalModelInventory for the weights).
//  Prior: none (new file, patterned on SelfQueryGate).
//

import M1K3Agent

public enum ToolPalettePolicy {
    /// What is actually there right now. Every field is a stable fact (see the
    /// file header), read fresh when the palette is built so a toggle, a finished
    /// download, or a first indexed document applies on the next turn.
    public struct Availability: Sendable, Equatable {
        /// The knowledge corpus has at least one indexed item — search/list/get
        /// have something to find.
        public var corpusHasItems: Bool
        /// The Settings web toggle allows the internet this turn.
        public var webAllowed: Bool
        /// A background dive would actually run on the bigger brain (resident IS
        /// Big, or DeepDiveTarget.plan would escalate to it). Without that, the
        /// tool only buys time on the same brain — cut from the palette.
        public var deepBrainAvailable: Bool
        /// The machine has a battery to report on (false on a desktop Mac).
        public var hasBattery: Bool

        public init(corpusHasItems: Bool, webAllowed: Bool, deepBrainAvailable: Bool, hasBattery: Bool) {
            self.corpusHasItems = corpusHasItems
            self.webAllowed = webAllowed
            self.deepBrainAvailable = deepBrainAvailable
            self.hasBattery = hasBattery
        }

        /// Everything present — the identity palette (useful for tests and for
        /// callers that gate elsewhere).
        public static let everything = Availability(
            corpusHasItems: true, webAllowed: true, deepBrainAvailable: true, hasBattery: true
        )
    }

    public static let knowledgeToolNames: Set<String> = ["search_knowledge", "list_documents", "get_document"]
    public static let webToolNames: Set<String> = ["web_search", "fetch_page", "lookup_fact", "open_link"]
    public static let deepBrainToolNames: Set<String> = ["delegate_deep"]
    public static let batteryToolNames: Set<String> = ["battery_status"]

    /// The names to withhold for this availability. Empty when everything is there.
    public static func excludedNames(for availability: Availability) -> Set<String> {
        var excluded = Set<String>()
        if !availability.corpusHasItems { excluded.formUnion(knowledgeToolNames) }
        if !availability.webAllowed { excluded.formUnion(webToolNames) }
        if !availability.deepBrainAvailable { excluded.formUnion(deepBrainToolNames) }
        if !availability.hasBattery { excluded.formUnion(batteryToolNames) }
        return excluded
    }

    /// Apply the policy to an assembled palette: order kept, names not governed
    /// here pass through untouched.
    public static func filter(_ tools: [any AgentTool], availability: Availability) -> [any AgentTool] {
        let excluded = excludedNames(for: availability)
        guard !excluded.isEmpty else { return tools }
        return tools.filter { !excluded.contains($0.name) }
    }
}
