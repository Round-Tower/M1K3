//
//  SensePermissionPolicy.swift
//  M1K3AgentTools
//
//  When a context sense asks macOS for permission (context-tools charter
//  rule 4, amended 2026-09-23). The rule was "the system dialog fires on first
//  TOOL use" — so switching Calendar or Location on did nothing visible until
//  a question happened to need it, and App Review asked whether a missing
//  alert was expected. Now the dialog fires the moment the user switches a
//  sense ON: still two consents, still ordered (the in-app switch first),
//  never at launch, never on switching off. A refusal — or a dismissed
//  dialog — flips the switch back, so it never promises a sense macOS will
//  not deliver.
//
//  Framework-free (the EventKit/CoreLocation status mapping lives in the app
//  target) so the rule is testable here.
//
//  Signed: Kev + claude-opus-5.5, 2026-09-23, Confidence 0.9 (pure, red-first
//  in SensePermissionPolicyTests; the dialogs themselves are verify-by-launch).
//  Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-10-10 (#540 / #544 fold) — `settledValue(before:answer:)`: the value
//  onboarding's Full door stores for a sense after its ceremony. The first cut wrote only the `false`
//  branches, so Full never turned calendar or location on (the bot pass caught it). Confidence 0.9.
//

/// macOS's answer for one sense, reduced to what the switch needs.
public enum SensePermissionStatus: Sendable, Equatable {
    case notDetermined
    case granted
    /// Denied, restricted, or (calendar) write-only — all mean "cannot read".
    case denied
}

/// What the Settings switch does next.
public enum SensePermissionAction: Sendable, Equatable {
    /// Leave the switch as the user set it.
    case keep
    /// Show the macOS permission dialog now.
    case request
    /// Flip the switch back off (the pane shows the System Settings path).
    case revert
}

public enum SensePermissionPolicy {
    /// The user just flipped a sense's switch.
    public static func onToggle(enabled: Bool, status: SensePermissionStatus) -> SensePermissionAction {
        guard enabled else { return .keep }
        switch status {
        case .notDetermined: return .request
        case .granted: return .keep
        case .denied: return .revert
        }
    }

    /// The dialog closed with this status.
    public static func afterRequest(_ status: SensePermissionStatus) -> SensePermissionAction {
        status == .granted ? .keep : .revert
    }

    /// Onboarding's Full door switches a sense ON through the same two steps
    /// as the pane, then STORES the outcome: `true` when macOS had already
    /// granted it or grants it now, `false` when it is denied, dismissed, or
    /// was never asked (`answer == nil` with a `.request` means the dialog
    /// could not be shown).
    public static func settledValue(before status: SensePermissionStatus, answer: SensePermissionStatus?) -> Bool {
        switch onToggle(enabled: true, status: status) {
        case .keep: return true
        case .revert: return false
        case .request:
            guard let answer else { return false }
            return afterRequest(answer) == .keep
        }
    }
}
