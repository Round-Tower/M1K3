//
//  WakeSetup.swift
//  M1K3Inference
//
//  The "set up the room while I wake" model — everything the wake-setup
//  carousel decides, pure and pinned, so the download wait's personality is
//  tested policy rather than view-code vibes. Three pieces:
//    · `WakeSetupFlow` — the card deck (free back-and-forth) plus the no-yank
//      completion rule: a user who never touched a card auto-completes on
//      ready exactly like today; anyone who engaged gets an invite to tap
//      through when THEY'RE ready, never a mid-card yank.
//    · `WakeProgressCopy` — the deterministic line-picker behind the progress
//      bar's caption (M1K3's own voice, percentage always honest, the name
//      saved for the home stretch).
//    · `WakeAlertness` — the avatar's ramp: waking up AS the bar fills is the
//      whole metaphor. The app maps these to concrete emotions.
//
//  Lives beside FirstRunBrainPolicy — onboarding policy belongs in the pure
//  layer. The SwiftUI carousel (M1K3App/WakeSetupCarousel.swift) only renders.
//
//  Signed: Kev + claude-fable-5, 2026-08-30, Confidence 0.9. Prior: none (new file).

import Foundation

/// The setup cards on offer while a brain downloads/warms. All optional, all
/// skippable — every one is a Settings surface that also happens to fit in a
/// card, so finishing the deck early costs nothing (the rest is just Settings,
/// where it always lived).
public enum WakeSetupCard: String, CaseIterable, Sendable, Identifiable {
    /// "Anything I should know?" — seeds the persona profile.
    case aboutYou
    /// How replies are typeset (the ROADMAP's ask-once-at-onboarding wish).
    case readingMode
    /// Built-in vs M1K3 Voice, with the "hear a sample" beat.
    case voice
    /// The companion face picker — the live backdrop is the preview.
    case face

    public var id: String {
        rawValue
    }
}

/// The card deck's state + the completion rule. A value type on purpose: the
/// view holds it in @State and every mutation is a plain, testable function.
public struct WakeSetupFlow: Sendable, Equatable {
    public private(set) var cards: [WakeSetupCard]
    public private(set) var index: Int = 0
    /// True once the user has touched ANY part of the carousel — moving
    /// through the deck or interacting with a card. Engagement is what buys
    /// the gentle invite over today's auto-advance.
    public private(set) var hasEngaged = false
    public private(set) var brainReady = false

    public init(cards: [WakeSetupCard] = WakeSetupCard.allCases) {
        self.cards = cards.isEmpty ? WakeSetupCard.allCases : cards
    }

    public var current: WakeSetupCard {
        cards[index]
    }

    public var canGoBack: Bool {
        index > 0
    }

    public var canAdvance: Bool {
        index < cards.count - 1
    }

    public mutating func advance() {
        hasEngaged = true
        if canAdvance { index += 1 }
    }

    public mutating func back() {
        hasEngaged = true
        if canGoBack { index -= 1 }
    }

    /// A card interaction that doesn't move the deck (typing a name, picking
    /// a face) still counts as engagement.
    public mutating func engage() {
        hasEngaged = true
    }

    public mutating func markBrainReady() {
        brainReady = true
    }

    /// What the view should do about completion right now.
    public enum Completion: Sendable, Equatable {
        /// Brain not ready yet — keep the carousel up.
        case keepWaiting
        /// Ready + the user never engaged: today's behaviour, straight to chat.
        case autoComplete
        /// Ready + the user is mid-setup: pulse the invite, wait for their tap.
        case invite
    }

    /// THE NO-YANK RULE, order-independent: readiness never interrupts a user
    /// who engaged, and never delays one who didn't.
    public var completion: Completion {
        guard brainReady else { return .keepWaiting }
        return hasEngaged ? .invite : .autoComplete
    }
}

/// The progress caption in M1K3's own voice — deterministic (same inputs,
/// same line; Reduce-Motion-safe by construction), percentage always honest,
/// and the user's name saved for the home stretch so the greeting lands as a
/// greeting, not a mail-merge.
public enum WakeProgressCopy {
    /// Caption for a determinate download. Caps at 99% — the moment of 100%
    /// belongs to `readyLine`, not a bar caption.
    public static func line(fraction: Double, name: String?) -> String {
        let pct = min(99, max(0, Int((fraction * 100).rounded())))
        switch fraction {
        case ..<0.15: return "fetching neurons… \(pct)%"
        case ..<0.35: return "wiring the synapses… \(pct)%"
        case ..<0.55: return "reading up on the world… \(pct)%"
        case ..<0.75: return "practising my accent… \(pct)%"
        case ..<0.9: return "getting my thoughts in order… \(pct)%"
        default:
            if let name, !name.isEmpty {
                return "nearly with you, \(name)… \(pct)%"
            }
            return "nearly with you… \(pct)%"
        }
    }

    /// The AFM warming wait has no fraction — cycle short lines by tick
    /// (the view advances the tick on its own clock).
    public static func warmingLine(tick: Int) -> String {
        let lines = [
            "Mini's stretching — no download, just waking up…",
            "Apple's on-device model is finishing a sync…",
            "almost with you…",
        ]
        return lines[((tick % lines.count) + lines.count) % lines.count]
    }

    /// The payoff at 100%: a greeting, not a state change. Spoken and shown.
    public static func readyLine(name: String?) -> String {
        if let name, !name.isEmpty {
            return "I'm awake, \(name) — let's chat"
        }
        return "I'm awake — let's chat"
    }
}

/// The avatar's wake-up ramp: visibly more alert as the download climbs.
/// The app maps these to concrete emotions (sleepy → neutral → thinking →
/// excited); the thresholds live here so the ramp is pinned.
public enum WakeAlertness: Sendable, Equatable {
    case dozing
    case stirring
    case alert
    case awake

    public static func at(fraction: Double, ready: Bool) -> WakeAlertness {
        if ready { return .awake }
        switch fraction {
        case ..<0.4: return .dozing
        case ..<0.8: return .stirring
        default: return .alert
        }
    }
}
