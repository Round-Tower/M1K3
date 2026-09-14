//
//  PrivateCloudRung.swift
//  M1K3LanguageModel
//
//  The Private Cloud Compute rung's surfaces (ADR 0006), as pure policy: when
//  the Settings switch and the per-request control exist, when one request
//  escalates, what the user is told when PCC can't answer, and the label a PCC
//  answer wears. The composition root reads the world (is a PCC backend in
//  this process, the consent key, the org switch, the quota) and passes plain
//  values; nothing here touches FoundationModels.
//
//  The load-bearing rule is that absence is silence. With no backend — every
//  build today, since the adapter needs the macOS 27 SDK and an entitlement
//  Apple hasn't granted — the switch is hidden, the control is hidden and no
//  request escalates, so the app behaves as 1.0 does. The same holds when an
//  organisation turns the rung off: ADR 0005's buyers need a hard "never
//  leaves", and an org switch overrides a user's yes.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85 (pure and total,
//  every input combination pinned; the PCC generation itself is verify-owed
//  until the entitlement). Prior: Unknown
//
//  Review: Kev + claude-opus-5, 2026-09-14 (later) — `presentsConsent`, lifted
//  from a three-clause `if` in ContentView (local review): images never ride a
//  PCC turn and an armed send needs a ready control, and both are now pinned
//  here rather than trusted to view code. `controlHelp` likewise: the control's
//  tooltip moved here, and an exhausted limit says when it resets (seen by
//  launch: it said only "for now"). `statusRecheckDelay` (review on 7b36869e):
//  an exhausted or unavailable control now re-reads the status until it can
//  be used; it used to recover only on relaunch. `resetPhrase` no longer
//  rounds minutes up to "about an hour" (seen by launch). Confidence now 0.85.
//

import Foundation

/// Mirror of `PrivateCloudComputeLanguageModel.quotaUsage` (macOS 27 SDK).
public enum PrivateCloudQuota: Sendable, Equatable {
    case belowLimit
    case limitReached(resetsAt: Date?)
    /// Not read yet, or the read failed. Not a reason to refuse: the send finds out.
    case unknown
}

/// Everything the rung decides from. Immutable inputs, read fresh by the caller.
public struct PrivateCloudState: Sendable, Equatable {
    /// A PCC backend exists in THIS process: the adapter is compiled in, the OS
    /// has the type, and the entitlement is present. Computed, never persisted.
    /// Availability alone is not enough: on 2026-09-13 an unentitled process
    /// read `available` and then failed every generation with 1046.
    public let backendPresent: Bool
    /// PCC's own runtime availability (network, region, service).
    public let available: Bool
    /// The raw persisted chat-egress consent (`ChatEgressConsent.defaultsKey`).
    public let consent: Bool?
    /// The organisation's policy switch (`PrivateCloudRung.managedOffDefaultsKey`).
    public let managedOff: Bool
    public let quota: PrivateCloudQuota

    public init(backendPresent: Bool, available: Bool, consent: Bool?, managedOff: Bool, quota: PrivateCloudQuota) {
        self.backendPresent = backendPresent
        self.available = available
        self.consent = consent
        self.managedOff = managedOff
        self.quota = quota
    }
}

public enum PrivateCloudRung {
    /// The defaults key an organisation sets (a configuration profile's managed
    /// preference lands in the app's defaults domain) to force the rung off.
    public static let managedOffDefaultsKey = "PrivateCloudComputeDisabledByPolicy"

    /// What Settings shows.
    public enum Setting: Sendable, Equatable {
        /// No backend in this build: the rung doesn't exist here.
        case hidden
        /// Present, but the organisation turned it off. Shown as a fact, not a control.
        case managedOff
        case shown(isOn: Bool)
    }

    /// What the per-request "ask Private Cloud Compute" control shows.
    public enum Control: Sendable, Equatable {
        case hidden
        case ready
        case unavailable
        case exhausted(resetsAt: Date?)
    }

    public static func setting(_ state: PrivateCloudState) -> Setting {
        guard state.backendPresent else { return .hidden }
        if state.managedOff { return .managedOff }
        return .shown(isOn: ChatEgressConsent.networkAllowed(persisted: state.consent))
    }

    public static func control(_ state: PrivateCloudState) -> Control {
        guard setting(state) == .shown(isOn: true) else { return .hidden }
        guard state.available else { return .unavailable }
        if case let .limitReached(resetsAt) = state.quota {
            return .exhausted(resetsAt: resetsAt)
        }
        return .ready
    }

    /// Whether an armed send goes to the consent sheet: only while the control is
    /// ready and no image is staged. Images never ride a PCC turn (ADR 0006).
    public static func presentsConsent(armed: Bool, control: Control, hasAttachments: Bool) -> Bool {
        armed && control == .ready && !hasAttachments
    }

    /// The control's tooltip: what a click does, or why it can't, and when an
    /// exhausted limit resets (the same reset words as the fallback notice).
    public static func controlHelp(_ control: Control, armed: Bool, now: Date) -> String {
        switch control {
        case .ready:
            armed
                ? "Your next message goes to Private Cloud Compute. You'll see it first."
                : "Send the next message to Apple's Private Cloud Compute"
        case .unavailable:
            "Private Cloud Compute isn't available right now"
        case let .exhausted(resetsAt):
            resetsAt.map {
                "You've reached your Private Cloud Compute limit. It resets "
                    + "\(PrivateCloudFallback.resetPhrase(until: $0, now: now))."
            } ?? "You've reached your Private Cloud Compute limit for now"
        case .hidden:
            ""
        }
    }

    /// How long to wait before re-reading PCC's status while the control can't be
    /// used, or nil when there's nothing to wait for. An exhausted limit is
    /// re-read at its reset, never more than 5 minutes apart (Apple's reset date
    /// is a promise, not a push) and never in a tight loop; unavailable, every
    /// minute. Without this, the control only recovered on relaunch.
    public static func statusRecheckDelay(for control: Control, now: Date) -> TimeInterval? {
        switch control {
        case .ready, .hidden:
            nil
        case .unavailable:
            60
        case let .exhausted(resetsAt):
            min(max(resetsAt.map { $0.timeIntervalSince(now) } ?? 300, 30), 300)
        }
    }

    /// The escalation for ONE request: PCC only when the user armed this send
    /// and the control is ready. Never automatic — a full Mini window is not a
    /// reason to leave the Mac (ADR 0006).
    public static func escalation(armed: Bool, _ state: PrivateCloudState) -> Escalation {
        armed && control(state) == .ready ? .privateCloud : .none
    }

    /// The ladder's egress gate for the PCC rung.
    public static func networkAllowed(_ state: PrivateCloudState) -> Bool {
        state.backendPresent && !state.managedOff
            && ChatEgressConsent.networkAllowed(persisted: state.consent)
    }
}

/// Why PCC couldn't answer. Mirrors the macOS 27 `LanguageModelError` cases the
/// rung acts on; the adapter maps into it.
public enum PrivateCloudFailure: Sendable, Equatable {
    case rateLimited
    case quotaLimitReached(resetsAt: Date?)
    case network
    case unavailable
    case other
}

/// The one sentence shown above the local brain's answer when PCC couldn't
/// answer. Never an empty bubble, and never a silent swap of brains.
public enum PrivateCloudFallback {
    public static func notice(for failure: PrivateCloudFailure, localBrain: String, now: Date) -> String {
        let tail = ", so \(localBrain) answered here instead."
        switch failure {
        case .rateLimited:
            return "Private Cloud Compute asked me to slow down" + tail
        case let .quotaLimitReached(resetsAt):
            let reset = resetsAt.map { " (it resets \(resetPhrase(until: $0, now: now)))" } ?? ""
            return "You've reached your Private Cloud Compute limit for now\(reset)" + tail
        case .network:
            return "I couldn't reach Private Cloud Compute" + tail
        case .unavailable:
            return "Private Cloud Compute isn't available right now" + tail
        case .other:
            return "Private Cloud Compute couldn't answer that one" + tail
        }
    }

    /// PCC stopped after some text arrived. What came stays (marked cut short);
    /// nothing local answered, so this line offers the local brain rather than
    /// claiming it — a partial answer is never silently replaced.
    public static func midAnswerNotice(for failure: PrivateCloudFailure, localBrain: String) -> String {
        let reason = switch failure {
        case .rateLimited: "it asked me to slow down"
        case .quotaLimitReached: "you've reached your limit for now"
        case .network: "the connection dropped"
        case .unavailable: "it became unavailable"
        case .other: "something went wrong on its side"
        }
        return "Private Cloud Compute stopped partway (\(reason)). Ask again without it and \(localBrain) will "
            + "answer here."
    }

    /// Coarse and honest: "shortly", "within the hour", hours up to a day, then
    /// "tomorrow", then days. Never rounds minutes up to an hour.
    static func resetPhrase(until reset: Date, now: Date) -> String {
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 120 else { return "shortly" }
        guard seconds > 45 * 60 else { return "within the hour" }
        let hours = Int((seconds / 3600).rounded(.up))
        switch hours {
        case ...1: return "in about an hour"
        case ...23: return "in about \(hours) hours"
        case ...47: return "tomorrow"
        default: return "in about \(Int((Double(hours) / 24).rounded())) days"
        }
    }
}

/// The label every PCC answer wears in the transcript (ADR 0006: visible, every time).
public enum PrivateCloudLabel {
    public static let text = "Private Cloud Compute"
    public static let accessibilityLabel = "Answered by Apple's Private Cloud Compute, not on this device"
    public static let symbolName = "cloud"
}
