//
//  HeartbeatComposer.swift
//  M1K3Heartbeat
//
//  The #102 guard, load-bearing: every fact a pulse carries is composed HERE,
//  deterministically, from the typed context — no retrieval, no tools, no
//  agent loop. The model's later narrative pass retells this digest; it never
//  originates content, and when its output fails NarrativeGuard this digest
//  IS the pulse. Phrasing follows doctrine principle 7 — plain words, no
//  engineering nouns ("running cool", never "thermal nominal") — and the
//  ratified platform-honesty noun: the machine, never the Mac.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.9 (pure function,
//  phrasing pinned by tests; whether the lines read well aloud is Kev's ear).
//  Prior: none (new file).
//  Review: Kev + claude-fable-5, 2026-08-30, Confidence 0.85 — the register
//  fixes from six live days (HEARTBEAT_DESIGN addendum 1–4): the chat line
//  gains its actor ("We talked about"), the brain line says what the brain
//  IS ("Running on Big, the larger brain"), the shelf metaphor goes ("From
//  your documents"), and the digest splits NEWS-first / AMBIENT-after.
//  Strings test-pinned; whether they read better in the model's mouth is
//  the named A/B, not an assertion here.
//

import Foundation

public enum HeartbeatComposer {
    /// Compose the deterministic digest for one pulse. Same context, same
    /// bytes — the tests pin it.
    ///
    /// Structure (2026-08-30 addendum, fix 4): NEWS (memory · chat · visiting
    /// agents) leads, AMBIENT (machine · brain) follows — device state is
    /// always present and never interesting, and an unstructured digest let
    /// the stable half outweigh the newsworthy half every pulse. A quiet
    /// digest carries no headers; there is nothing to lead with (and the
    /// render gate means it never reaches the model anyway).
    public static func digest(from context: HeartbeatContext) -> String {
        var news: [String] = []
        if let memory = memoryLines(context.memory) { news.append(memory) }
        if let chat = chatLine(context.chat) { news.append(chat) }
        if let mcp = mcpLine(context.mcp) { news.append(mcp) }

        var ambient: [String] = []
        ambient.append(deviceLine(context.device))
        if let battery = batteryLine(context.device) { ambient.append(battery) }
        if let disk = diskLine(context.device) { ambient.append(disk) }
        if let uptime = uptimeLine(context.device) { ambient.append(uptime) }
        if let brain = brainLine(context.brain) { ambient.append(brain) }

        var lines: [String] = []
        if news.isEmpty {
            lines.append("A quiet stretch — nothing new since the last pulse.")
            lines.append(contentsOf: ambient)
        } else {
            lines.append("News:")
            lines.append(contentsOf: news)
            lines.append("Ambient:")
            lines.append(contentsOf: ambient)
        }
        if let fact = context.funFact {
            // A remembered fact's title often IS its body (truncated) — a
            // duplicate bracket reads broken (first live pulse, 2026-08-06).
            // "From your documents", not "from the shelf": the closed noun
            // list already spends `documents` on the corpus, and the shelf
            // metaphor was exactly the phrase the model borrowed for the
            // brain (fix 3).
            let bareTitle = fact.sourceTitle.trimmingCharacters(in: CharacterSet(charactersIn: "…, "))
            if fact.text.hasPrefix(bareTitle) || bareTitle.hasPrefix(fact.text) {
                lines.append("From your documents: \(fact.text)")
            } else {
                lines.append("From your documents: \(fact.text) [\(fact.sourceTitle)]")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Sentence-safe excerpt for the fun fact: cut at the last sentence end
    /// within `maxLength`; failing that, at a word boundary with an ellipsis.
    public static func excerpt(_ text: String, maxLength: Int = 180) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let window = String(trimmed.prefix(maxLength))
        if let lastEnd = window.lastIndex(where: { ".!?".contains($0) }) {
            return String(window[...lastEnd])
        }
        if let lastSpace = window.lastIndex(of: " ") {
            return String(window[..<lastSpace]) + "…"
        }
        return window + "…"
    }

    private static func deviceLine(_ device: HeartbeatContext.Device) -> String {
        var line: String
        switch device.thermal {
        case .nominal: line = "The machine is running cool."
        case .fair: line = "The machine is a touch warm."
        case .serious, .critical: line = "The machine is running hot."
        }
        if device.lowPowerMode {
            line += " Low Power Mode is on."
        }
        return line
    }

    private static func batteryLine(_ device: HeartbeatContext.Device) -> String? {
        guard let percent = device.batteryPercent else { return nil }
        let state = (device.isCharging ?? false) ? "charging" : "on battery"
        return "Battery at \(percent)%, \(state)."
    }

    private static func diskLine(_ device: HeartbeatContext.Device) -> String? {
        guard let free = device.diskFreeGB, let total = device.diskTotalGB else { return nil }
        return "\(Int(free.rounded())) GB free of \(Int(total.rounded())) GB on disk."
    }

    /// #103 review: uptime was gathered but never told. Plain words, coarse
    /// bands — nobody needs minutes.
    private static func uptimeLine(_ device: HeartbeatContext.Device) -> String? {
        guard let hours = device.uptimeHours, hours >= 1 else { return nil }
        if hours >= 48 {
            return "Up \(Int(hours / 24)) days."
        }
        if hours >= 24 {
            return "Up a day."
        }
        return "Up \(Int(hours)) hours."
    }

    private static func memoryLines(_ memory: HeartbeatContext.MemoryActivity?) -> String? {
        guard let memory else { return nil }
        var parts: [String] = []
        if !memory.newFactTitles.isEmpty {
            let shown = memory.newFactTitles.prefix(3).joined(separator: ", ")
            let overflow = memory.newFactTitles.count - 3
            let tail = overflow > 0 ? ", and \(overflow) more" : ""
            let noun = memory.newFactTitles.count == 1 ? "thing" : "things"
            parts.append("Learned \(memory.newFactTitles.count) new \(noun): \(shown)\(tail).")
        }
        if memory.supersededCount > 0 {
            let noun = memory.supersededCount == 1 ? "fact" : "facts"
            parts.append("Corrected \(memory.supersededCount) remembered \(noun).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Named actor, mutual voice (fix 1): the old "Conversations touched:"
    /// passive left the model to fill the gap — as M1K3's own work, or as a
    /// report filed on the user. A resident says WE; a monitor says you were
    /// observed.
    private static func chatLine(_ chat: HeartbeatContext.ChatActivity?) -> String? {
        guard let chat, !chat.touchedConversationTitles.isEmpty else { return nil }
        let titles = chat.touchedConversationTitles.prefix(3)
            .map { "'\($0)'" }
            .joined(separator: ", ")
        return "We talked about \(titles)."
    }

    private static func mcpLine(_ mcp: HeartbeatContext.MCPActivity?) -> String? {
        guard let mcp, mcp.callCount > 0 else { return nil }
        if mcp.topTools.isEmpty {
            return "\(mcp.callCount) visiting-agent calls."
        }
        let tools = mcp.topTools.prefix(3).joined(separator: ", ")
        return "\(mcp.callCount) visiting-agent calls (\(tools))."
    }

    /// The brain is what M1K3 thinks WITH (fix 2): "Big is resident." made
    /// an unexplained proper noun of it, and a bare generate gave it the
    /// friendliest available reading — a housemate on the shelf, three
    /// pulses running.
    private static func brainLine(_ brain: HeartbeatContext.BrainStatus?) -> String? {
        guard let brain else { return nil }
        var parts: [String] = []
        if let resident = brain.residentTierName {
            if let descriptor = brain.residentTierDescriptor {
                parts.append("Running on \(resident), \(descriptor).")
            } else {
                parts.append("Running on \(resident).")
            }
        }
        if let downloading = brain.downloadingModelName {
            parts.append("Fetching \(downloading).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

public extension HeartbeatContext {
    /// Movement worth pulsing about — device state and a fun fact alone are
    /// ambience, not activity (the empty rule reads this).
    var hasActivity: Bool {
        if let memory, !memory.newFactTitles.isEmpty || memory.supersededCount > 0 { return true }
        if let chat, !chat.touchedConversationTitles.isEmpty { return true }
        if let mcp, mcp.callCount > 0 { return true }
        return false
    }
}
