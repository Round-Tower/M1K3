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
//

import Foundation

public enum HeartbeatComposer {
    /// Compose the deterministic digest for one pulse. Same context, same
    /// bytes — the tests pin it.
    public static func digest(from context: HeartbeatContext) -> String {
        var lines: [String] = []
        lines.append(deviceLine(context.device))
        if let battery = batteryLine(context.device) { lines.append(battery) }
        if let disk = diskLine(context.device) { lines.append(disk) }
        if let memory = memoryLines(context.memory) { lines.append(memory) }
        if let chat = chatLine(context.chat) { lines.append(chat) }
        if let mcp = mcpLine(context.mcp) { lines.append(mcp) }
        if let brain = brainLine(context.brain) { lines.append(brain) }
        if !context.hasActivity {
            lines.append("A quiet stretch — nothing new since the last pulse.")
        }
        if let fact = context.funFact {
            lines.append("From the shelf: \(fact.text) [\(fact.sourceTitle)]")
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

    private static func memoryLines(_ memory: HeartbeatContext.MemoryActivity?) -> String? {
        guard let memory else { return nil }
        var parts: [String] = []
        if !memory.newFactTitles.isEmpty {
            let shown = memory.newFactTitles.prefix(3).joined(separator: ", ")
            let overflow = memory.newFactTitles.count - 3
            let tail = overflow > 0 ? ", and \(overflow) more" : ""
            parts.append("Learned \(memory.newFactTitles.count) new things: \(shown)\(tail).")
        }
        if memory.supersededCount > 0 {
            parts.append("Corrected \(memory.supersededCount) remembered facts.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func chatLine(_ chat: HeartbeatContext.ChatActivity?) -> String? {
        guard let chat, !chat.touchedConversationTitles.isEmpty else { return nil }
        let titles = chat.touchedConversationTitles.prefix(3)
            .map { "'\($0)'" }
            .joined(separator: ", ")
        return "Conversations touched: \(titles)."
    }

    private static func mcpLine(_ mcp: HeartbeatContext.MCPActivity?) -> String? {
        guard let mcp, mcp.callCount > 0 else { return nil }
        if mcp.topTools.isEmpty {
            return "\(mcp.callCount) visiting-agent calls."
        }
        let tools = mcp.topTools.prefix(3).joined(separator: ", ")
        return "\(mcp.callCount) visiting-agent calls (\(tools))."
    }

    private static func brainLine(_ brain: HeartbeatContext.BrainStatus?) -> String? {
        guard let brain else { return nil }
        var parts: [String] = []
        if let resident = brain.residentTierName {
            parts.append("\(resident) is resident.")
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
