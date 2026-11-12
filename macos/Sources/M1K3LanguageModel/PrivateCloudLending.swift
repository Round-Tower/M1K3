//
//  PrivateCloudLending.swift
//  M1K3LanguageModel
//
//  Private Cloud Compute, lent to other apps on this Mac (the Local API's
//  `cloud-m1k3` model and the MCP server's `ask_private_cloud` tool), as pure
//  policy (ADR 0011). Two yeses, both the owner's: the lending switch for that
//  surface, off by default, AND the chat rung's own gate (a backend in this
//  process, no organisation policy against it, the Privacy pane's Private
//  Cloud Compute switch on). Either no ends it: turning the Privacy switch off
//  takes the lent model away with it.
//
//  What leaves is the caller's own words and nothing of M1K3's: no persona, no
//  memory, no knowledge, no chat history. That is why the chat's consent sheet
//  (`PrivateCloudArming`, which shows the M1K3 history about to leave) is not
//  on this path: there is no M1K3 history on it to show.
//
//  One fixed line of M1K3's does ride along since 2026-11-12: the acceptable-use
//  rule Apple's licence asks for (`LentAppleModelGuardrail`). It is a rule for
//  the model, not anything of the owner's.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.8 (pure and pinned),
//  Prior: none (new file). Context: Kev, 2026-11-12: "people want PCC available
//  via the OpenAI server, and via MCP".
//

import Foundation

public enum PrivateCloudLending {
    /// The Local API model id. Named for where the answer comes from, so no
    /// client config can mistake it for a brain on this Mac.
    public static let modelID = "cloud-m1k3"
    /// The MCP tool.
    public static let toolName = "ask_private_cloud"

    /// What another app is offered right now.
    public enum Offer: Sendable, Equatable {
        case notOffered
        case ready
        case unavailable
        case exhausted(resetsAt: Date?)

        /// Listed whenever it is offered, ready or not: a call is then told why
        /// it cannot be served instead of "no such model".
        public var isListed: Bool {
            self != .notOffered
        }
    }

    public static func offer(switchOn: Bool, control: PrivateCloudRung.Control) -> Offer {
        guard switchOn else { return .notOffered }
        switch control {
        case .hidden: return .notOffered
        case .ready: return .ready
        case .unavailable: return .unavailable
        case let .exhausted(resetsAt): return .exhausted(resetsAt: resetsAt)
        }
    }

    /// The Local API's model list: the brains on this Mac first, the cloud id LAST. A client that takes the
    /// first id it is given (many do) then stays on this Mac whenever a brain here is ready.
    public static func modelIDs(local: [String], offer: Offer) -> [String] {
        offer.isListed ? local.filter { $0 != modelID } + [modelID] : local.filter { $0 != modelID }
    }

    /// What a call is told when it cannot be served; nil when it can.
    public static func refusal(_ offer: Offer, now: Date) -> String? {
        switch offer {
        case .ready:
            return nil
        case .notOffered:
            return "Private Cloud Compute isn't open to other apps. M1K3's owner can turn it on in "
                + "M1K3 ▸ Settings ▸ Server."
        case .unavailable:
            return "Private Cloud Compute isn't available right now."
        case let .exhausted(resetsAt):
            let reset = resetsAt.map { " It resets \(PrivateCloudFallback.resetPhrase(until: $0, now: now))." } ?? ""
            return "This Mac has reached its Private Cloud Compute limit for now.\(reset)"
        }
    }

    /// What a tool call is told when Private Cloud Compute failed on its side.
    public static func failureLine(_ failure: PrivateCloudFailure, now: Date) -> String {
        switch failure {
        case .rateLimited: "Private Cloud Compute asked M1K3 to slow down. Try again shortly."
        case let .quotaLimitReached(resetsAt): refusal(.exhausted(resetsAt: resetsAt), now: now) ?? ""
        case .network: "M1K3 couldn't reach Private Cloud Compute."
        case .unavailable: refusal(.unavailable, now: now) ?? ""
        case .other: "Private Cloud Compute couldn't answer that one."
        }
    }

    /// What a call over the hourly budget is told.
    public static func overBudgetLine(retryAfter seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded(.up)))
        return "Other apps have asked Private Cloud Compute \(Budget.callsPerHour) times in the last hour, which is "
            + "M1K3's limit for lent calls. Try again in about \(minutes) minute\(minutes == 1 ? "" : "s")."
    }

    /// A ceiling on lent calls, shared by both surfaces: a tool in a loop must not spend the owner's whole
    /// daily Private Cloud Compute limit, which their own chat draws on. Rolling, in memory, per launch.
    public struct Budget: Sendable, Equatable {
        /// Open (ADR 0011): a first number, not a measured one. Apple does not publish the daily limit.
        public static let callsPerHour = 30
        static let window: TimeInterval = 3600

        private var spent: [Date] = []

        public init() {}

        /// Takes one call from the budget. Nil when it may go; otherwise the seconds until one frees up.
        public mutating func spend(now: Date) -> Int? {
            spent.removeAll { now.timeIntervalSince($0) >= Self.window }
            guard spent.count >= Self.callsPerHour else {
                spent.append(now)
                return nil
            }
            let oldest = spent.first ?? now
            // Never more than the window: a clock set backwards must not turn an hour's wait into a day's.
            let wait = Int((Self.window - now.timeIntervalSince(oldest)).rounded(.up))
            return min(Int(Self.window), max(1, wait))
        }
    }

    /// The calls that have left for Private Cloud Compute since launch, by surface: one tally beside the one
    /// budget, shown on the Settings pane so the traffic is never unseen.
    public struct Tally: Sendable, Equatable {
        public private(set) var localAPI = 0
        public private(set) var agents = 0

        public init() {}

        public var total: Int {
            localAPI + agents
        }

        /// Counts one call and returns the new total.
        public mutating func countLocalAPI() -> Int {
            localAPI += 1
            return total
        }

        public mutating func countAgent() -> Int {
            agents += 1
            return total
        }
    }

    /// The lending switch's row in Settings.
    public enum Row: Sendable, Equatable {
        /// The rung cannot exist in this build: no row.
        case hidden
        /// The organisation turned Private Cloud Compute off: shown as a fact.
        case managedOff
        /// The Privacy pane's switch is off: the row says to turn that on first. It still shows the STORED
        /// answer, so lending that would resume with the Privacy switch is never a hidden yes.
        case needsPrivacySwitch(isOn: Bool)
        case toggle(isOn: Bool)
    }

    public static func row(switchOn: Bool, setting: PrivateCloudRung.Setting) -> Row {
        switch setting {
        case .hidden: .hidden
        case .managedOff: .managedOff
        case .shown(isOn: false): .needsPrivacySwitch(isOn: switchOn)
        case .shown(isOn: true): .toggle(isOn: switchOn)
        }
    }
}
