//
//  StarterPrompts.swift
//  M1K3Chat
//
//  The blank-canvas chips. Three fixed strings read as furniture after the
//  second launch; now the chips are drawn from a pool, shuffled per visit, with
//  up to two woven from the user's most recent memories so the canvas says
//  "I remember" before a word is typed (Kev, QA pass 2026-09-05, item 10). Pure:
//  the shell passes recent memory titles and a generator; the tests pass a
//  seeded one.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.85 (pinned by
//  StarterPromptsTests; the pool copy is a taste call). Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-09-11 — the context-aware rule (`Context`, `candidates(for:)`,
//  `pick(context:count:using:)`): one door chip always, at most two chips from what the stores hold
//  right now (memories, recent chats, todos, the latest pulse, today's visitors, the hour), at least
//  one pool chip for the fun of it, reshuffled per fresh canvas. Kev: "the 'What can you do' section
//  be context aware of current context & some randomness for fun." The Mac uses it; the iOS
//  `pick(memoryTitles:)` rule keeps its shape (three phone chips, the two-memory beat) and draws
//  from `phonePool` = pool + door, so moving "What do you remember about me?" to the door took
//  nothing off the phone (review catch). "This week" softened to "lately" — the context carries no
//  timestamps, so the chip must not promise a window the answer (recent_activity) decides for itself;
//  the activity gate reads the same trimmed titles as the chips (a blank-only title is no activity);
//  the phone's memory chips fold embedded newlines through the same `trimmed` (was ends-only).
//

import Foundation

public enum StarterPrompts {
    /// Chips must stay one line on a phone.
    public static let maxChipLength = 44

    /// At most this many chips come from memories; the rest from the pool.
    public static let maxMemoryChips = 2

    public static let pool: [String] = [
        "What can you help me with?",
        "Explain something simply",
        "Give me a two-minute plan for today",
        "Teach me one new word",
        "Help me think through a decision",
        "Summarise what's on my mind",
        "Tell me something surprising",
        "Draft a short message for me",
        "Quiz me on something I know",
    ]

    /// The phone's draw: the pool plus the door chips (the phone has no door slot
    /// of its own, so the door questions ride in its shuffle).
    public static let phonePool: [String] = pool + doorPool

    /// Three chips: up to two from `memoryTitles` (newest first, blanks skipped,
    /// long titles trimmed), the rest a shuffle of `phonePool`. Never duplicates.
    /// `count` beyond the pool + memory chips returns what exists, no repeats.
    public static func pick(
        memoryTitles: [String],
        count: Int = 3,
        using rng: inout some RandomNumberGenerator
    ) -> [String] {
        // Dedupe AFTER trimming to chip form: two memories with the same title,
        // or two long titles that collide once truncated, must not print twice.
        var picks: [String] = []
        for title in memoryTitles where picks.count < min(maxMemoryChips, count) {
            let oneLine = trimmed(title) // folds embedded newlines too, like the Mac path
            guard !oneLine.isEmpty else { continue }
            let chip = memoryChip(oneLine)
            if !picks.contains(chip) { picks.append(chip) }
        }
        for prompt in phonePool.shuffled(using: &rng) where picks.count < count {
            if !picks.contains(prompt) { picks.append(prompt) }
        }
        return picks.shuffled(using: &rng)
    }

    private static func memoryChip(_ title: String) -> String {
        let lead = "Remind me about "
        let room = maxChipLength - lead.count - 1
        guard title.count > room else { return lead + title }
        return lead + title.prefix(room).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - The context-aware rule (Mac, 2026-09-11)

    /// What the stores hold right now — plain data the shell gathers on the
    /// main actor (cheap reads: titles, counts, one date, the hour).
    public struct Context: Sendable, Equatable {
        /// Newest first.
        public var memoryTitles: [String]
        /// Recent conversations, newest first, titled only (the drawer's own list).
        public var conversationTitles: [String]
        public var openTodoCount: Int
        public var overdueTodoCount: Int
        /// Seconds since the latest heartbeat pulse; nil when there is none.
        public var latestPulseAge: TimeInterval?
        /// MCP visitor calls since midnight (0 when the log is off).
        public var visitorCallsToday: Int
        /// Self-reported MCP client names today, in the log's own order
        /// (alphabetical, not most-recent — the first non-blank one is named).
        /// UNTRUSTED: the name lands in a chip that, tapped, is sent as the
        /// user's own words. Folded to one line and capped; never anything more.
        public var visitorNames: [String]
        /// The local hour, 0–23.
        public var hour: Int

        public init(
            memoryTitles: [String] = [], conversationTitles: [String] = [],
            openTodoCount: Int = 0, overdueTodoCount: Int = 0, latestPulseAge: TimeInterval? = nil,
            visitorCallsToday: Int = 0, visitorNames: [String] = [], hour: Int = 12
        ) {
            self.memoryTitles = memoryTitles
            self.conversationTitles = conversationTitles
            self.openTodoCount = openTodoCount
            self.overdueTodoCount = overdueTodoCount
            self.latestPulseAge = latestPulseAge
            self.visitorCallsToday = visitorCallsToday
            self.visitorNames = visitorNames
            self.hour = hour
        }

        public static let empty = Context()
    }

    /// Where a context chip came from; each source has a cap so one busy
    /// store cannot fill every slot.
    public enum Source: Sendable, Equatable, CaseIterable {
        case memory, conversation, todos, pulse, visitors, activity, timeOfDay

        public var cap: Int {
            switch self {
            case .memory, .conversation: 2
            default: 1
            }
        }
    }

    public struct Candidate: Sendable, Equatable {
        public let source: Source
        public let text: String
    }

    /// One of these always shows — the door in. "What can you do?" is the
    /// capability probe the persona already answers well; the others open the
    /// same door from a different angle.
    public static let doorPool: [String] = [
        "What can you do?",
        "What's new with you?",
        "What do you remember about me?",
    ]

    /// At most this many chips come from the context; the rest are the door
    /// and the pool, so there is always something random on the canvas.
    public static let maxContextChips = 2

    /// A pulse older than this is not "while I was away".
    static let freshPulseAge: TimeInterval = 36 * 3600

    /// Every chip the context can justify, in source order, capped per source,
    /// already trimmed to one line. Pure — the tests pin each rule.
    public static func candidates(for context: Context) -> [Candidate] {
        var out: [Candidate] = []
        func add(_ source: Source, _ text: String) {
            guard out.count(where: { $0.source == source }) < source.cap else { return }
            guard !out.contains(where: { $0.text == text }) else { return }
            out.append(Candidate(source: source, text: text))
        }
        let memoryTitles = context.memoryTitles.map(trimmed).filter { !$0.isEmpty }
        let conversationTitles = context.conversationTitles.map(trimmed).filter { !$0.isEmpty }
        for title in memoryTitles {
            add(.memory, memoryChip(title))
        }
        for title in conversationTitles {
            add(.conversation, fit(lead: "Pick up “", title, tail: "”?"))
        }
        if context.overdueTodoCount > 0 {
            add(.todos, "What's overdue?")
        } else if context.openTodoCount > 0 {
            add(.todos, "What's on my list?")
        }
        if let age = context.latestPulseAge, age <= freshPulseAge {
            add(.pulse, "What did you notice while I was away?")
        }
        if context.visitorCallsToday > 0 {
            if let name = context.visitorNames.map(trimmed).first(where: { !$0.isEmpty }) {
                add(.visitors, fit(lead: "What did ", name, tail: " want today?"))
            } else {
                add(.visitors, "What have the visitors been up to?")
            }
        }
        // "Lately", not "this week": titles carry no dates here, so the chip
        // names no window — recent_activity picks the window when it answers.
        // Gated on the SAME trimmed titles as the chips above, so a blank-only
        // title can never promise activity with no chip behind it.
        let hasActivity = !conversationTitles.isEmpty || !memoryTitles.isEmpty
            || context.visitorCallsToday > 0
        if hasActivity {
            add(.activity, "What have we been up to lately?")
        }
        switch context.hour {
        case 5 ... 11: add(.timeOfDay, "Morning. Two-minute plan for today?")
        case 22 ... 23, 0 ... 4: add(.timeOfDay, "It's late. One calm thought?")
        default: break
        }
        return out
    }

    /// `count` chips for a fresh canvas: one door (random), up to
    /// `maxContextChips` drawn at random from the candidates (already capped
    /// per source by `candidates(for:)`), the rest from the pool — so the
    /// canvas always carries what the stores know AND something it didn't
    /// have to. From three chips up, one slot is always the pool's, so at
    /// count 3 the context gets ONE chip and two only from count 4 (the Mac's
    /// four). Never duplicates; final order shuffled. The fixed strings (door,
    /// pool, the context templates) are disjoint by construction — pinned by
    /// `fixedStringsAreDisjoint`.
    public static func pick(
        context: Context,
        count: Int = 4,
        using rng: inout some RandomNumberGenerator
    ) -> [String] {
        guard count > 0 else { return [] }
        var picks: [String] = []
        if let door = doorPool.randomElement(using: &rng) { picks.append(door) }
        // Room for context chips, keeping at least one pool slot when there
        // are three or more chips in total.
        let contextRoom = min(maxContextChips, max(0, count - picks.count - (count >= 3 ? 1 : 0)))
        for candidate in candidates(for: context).shuffled(using: &rng)
            where picks.count - 1 < contextRoom
        {
            guard !picks.contains(candidate.text) else { continue }
            picks.append(candidate.text)
        }
        for prompt in pool.shuffled(using: &rng) where picks.count < count {
            if !picks.contains(prompt) { picks.append(prompt) }
        }
        return picks.shuffled(using: &rng)
    }

    /// One line, trimmed: newlines and control characters fold to a space
    /// first (visitor names are self-reported, titles can carry anything —
    /// the ActivityDigest.sanitized precedent), runs of whitespace collapse
    /// to one space (a CRLF is two scalars), so a chip can never wrap.
    private static func trimmed(_ text: String) -> String {
        let folded = String(text.unicodeScalars.map { scalar -> Character in
            CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
                ? " " : Character(scalar)
        })
        return folded
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// `lead + text + tail`, the text trimmed so the whole chip stays one line.
    private static func fit(lead: String, _ text: String, tail: String) -> String {
        let room = maxChipLength - lead.count - tail.count - 1
        guard text.count > room else { return lead + text + tail }
        return lead + text.prefix(room).trimmingCharacters(in: .whitespaces) + "…" + tail
    }
}
