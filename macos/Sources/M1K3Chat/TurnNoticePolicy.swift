//
//  TurnNoticePolicy.swift
//  M1K3Chat
//
//  The iPhone's "your answer is ready" local notification, as pure decisions (the Mac's twin is
//  TurnNotificationPolicy + AppEnvironment+Notifications). When a turn the app followed (a chat answer, a
//  read, a look, Private Cloud) lands while the app is NOT in front, one notice goes out: generic words,
//  never the question, the answer or a file name (a banner reads on a locked screen). Unlike the Mac there
//  is no 8 s floor on the notice itself: the person left mid-turn, and any answer that lands after that is
//  news. The 8 s mark gates only the permission ask (below).
//
//  PERMISSION: the phone has no notification setting, so the system prompt is asked ONCE, right after a
//  long answer (>= `TurnNotificationPolicy.longTurnThreshold`) lands in the foreground: after the answer, never
//  mid-answer, and at the moment the value is plain ("next time, leave and I'll tell you").
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.75 (decisions pinned in TurnNoticePolicyTests;
//  the banner and the prompt are verify-on-device), Prior: TurnNotificationPolicy (Kev + claude-opus-4-8,
//  2026-06-14), the Mac's version of the same ping.
//  Review: claude-opus-5-5, 2026-11-19 — localisation Phase 0: the notice's title and body resolve from M1K3Chat's
//  own catalog (`bundle: .module`). English unchanged.

import Foundation

public enum TurnNoticePolicy {
    /// The three things worth a ping. Fixed copy: nothing about the turn is interpolated.
    public enum Notice: Sendable, Equatable {
        case answerReady
        case readFinished
        /// The exit stopped the answer; opening M1K3 is the way back.
        case paused

        /// A title never names the app: the banner already does (the Mac's rule, Kev 2026-08-30).
        public var title: String {
            switch self {
            case .answerReady: String(localized: "Your answer's ready", bundle: .module)
            case .readFinished: String(localized: "Finished reading", bundle: .module)
            case .paused: String(localized: "Your answer paused", bundle: .module)
            }
        }

        public var body: String {
            switch self {
            case .answerReady: String(localized: "It's waiting in the chat.", bundle: .module)
            case .readFinished: String(localized: "The answer is waiting in the chat.", bundle: .module)
            case .paused: String(localized: "Open M1K3 to finish your answer.", bundle: .module)
            }
        }
    }

    /// Every turn notice shares one identifier (a later one replaces the earlier, so a Paused that is then
    /// answered leaves one banner) and one thread. No badge is ever set.
    public static let identifier = "turn.notice"
    public static let threadIdentifier = "turn"

    /// The notice for a turn that just ended, nil for none.
    public static func notice(for outcome: TurnActivityPolicy.Outcome, kind: TurnKind, appActive: Bool) -> Notice? {
        guard outcome == .answered, !appActive else { return nil }
        return kind == .read ? .readFinished : .answerReady
    }

    /// Whether to ask for notification permission now (the system shows its prompt only while undecided).
    public static func shouldAskPermission(
        for outcome: TurnActivityPolicy.Outcome, duration: Duration, appActive: Bool
    ) -> Bool {
        outcome == .answered && appActive && duration >= TurnNotificationPolicy.longTurnThreshold
    }
}

/// What a followed turn is, for the words ("Finished reading").
public enum TurnKind: Sendable, Equatable {
    case answer
    case read
}
