//
//  AppStateLine.swift
//  M1K3Inference
//
//  One line telling the brain what is true about M1K3 right now (a brain downloading, loading, failed,
//  just ready, or Apple Intelligence still getting ready), so "is it ready now?" gets a true answer.
//  The first App Store review (iPhone, 2026-11-01) asked exactly that and got a ramble: no prompt
//  carried any of it. Nil in the steady state, so ordinary prompts don't change by a byte.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.8 (the wording is measured on Mini by
//  MiniAppStateEvalTests; the shells' snapshots are verify-by-launch). Prior: Unknown.
//

import Foundation

/// What the shells know about the chosen brain, captured where a turn can read it off the main actor.
public struct AppStateSnapshot: Sendable, Equatable {
    /// The chosen brain's user-facing name ("Lil", "Mini").
    public var brain: String
    public var load: ModelLoadState
    /// Who answers right now when it isn't `brain` (the Mac's interim Mini, Brain at Home), else nil.
    public var answeringBrain: String?
    public var downloadStalled: Bool
    /// When `load` last became `.ready`, for the "just finished" line.
    public var readySince: Date?
    /// Mini is chosen and Apple Intelligence reports its model isn't ready yet.
    public var appleIntelligenceGettingReady: Bool

    public init(
        brain: String, load: ModelLoadState, answeringBrain: String? = nil, downloadStalled: Bool = false,
        readySince: Date? = nil, appleIntelligenceGettingReady: Bool = false
    ) {
        self.brain = brain
        self.load = load
        self.answeringBrain = answeringBrain
        self.downloadStalled = downloadStalled
        self.readySince = readySince
        self.appleIntelligenceGettingReady = appleIntelligenceGettingReady
    }
}

public enum AppStateLine {
    /// How long "finished getting ready" stays true enough to say: the turn right after a download.
    public static let justReadyWindow: TimeInterval = 600

    public static func render(_ state: AppStateSnapshot, now: Date = Date()) -> String? {
        let lead = "M1K3 right now:"
        if state.appleIntelligenceGettingReady {
            return "\(lead) Apple Intelligence is still getting ready on this device, so \(state.brain) isn't ready yet."
        }
        let meanwhile = state.answeringBrain.map { " \($0) is answering until then." } ?? ""
        switch state.load {
        case let .downloading(fraction) where fraction < 1:
            let stall = state.downloadStalled ? " The download has stalled: it needs Wi-Fi, and M1K3 kept open." : ""
            return "\(lead) \(state.brain) is still downloading (\(percent(fraction))), so it isn't ready yet.\(stall)\(meanwhile)"
        case .downloading, .preparing:
            return "\(lead) \(state.brain) is downloaded and still loading, so it isn't ready yet.\(meanwhile)"
        case let .failed(message):
            return "\(lead) \(state.brain) couldn't load: \(clipped(message))"
        case .ready:
            guard let since = state.readySince, now.timeIntervalSince(since) <= justReadyWindow else { return nil }
            return "\(lead) \(state.brain) finished getting ready and is answering now."
        case .idle:
            return nil
        }
    }

    /// A failure message as one short line: newlines flattened, cut at `messageLimit` characters.
    static let messageLimit = 160

    private static func clipped(_ message: String) -> String {
        let flat = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > messageLimit ? String(flat.prefix(messageLimit - 1)) + "…" : flat
    }

    /// The bar's rounding: a started download under half a percent reads "<1%", never "0%".
    private static func percent(_ fraction: Double) -> String {
        let fraction = min(max(fraction, 0), 1)
        let whole = Int((fraction * 100).rounded())
        return whole == 0 && fraction > 0 ? "<1%" : "\(whole)%"
    }
}
