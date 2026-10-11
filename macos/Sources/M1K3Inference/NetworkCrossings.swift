//
//  NetworkCrossings.swift
//  M1K3Inference
//
//  The one list of the ways M1K3 reaches the internet, per build lane, so the in-app copy cannot
//  drift from the facts again. HelloView's privacy line and the Privacy pane's Tools footer both
//  said web search was "the one thing that sends anything out"; since the downloads grew (brains,
//  the pocket Mini on a Mac without Apple Intelligence, the semantic-memory embedder, WhisperKit's
//  speech models, Kokoro's model and its voice pack) that was false.
//
//  Downloads today (`DownloadKind` is exhaustive here, so a new one must declare its host):
//    · brains (Lil, Big, the pocket Mini) and the embedder .... huggingface.co
//    · sharper ears (WhisperKit) ................................ huggingface.co
//    · M1K3 Voice (Kokoro) ...................................... huggingface.co + github.com
//      (the model from Hugging Face; `voices-v1.0.bin` from a github.com release)
//  The lanes differ in one place: only the App Store build carries the opt-in Private Cloud Compute
//  backend (`AppEnvironment.privateCloudBackend`). This file never claims "huggingface.co only".
//  The site (`site/privacy.html`) and the store descriptions are hand-written from the same list.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure; pinned by NetworkCrossingsTests).
//  Prior: none (new file).

import Foundation

public enum NetworkCrossings {
    /// Which build this is, as far as the network goes.
    public enum Lane: Sendable, Equatable {
        /// The App Store / TestFlight build: carries the opt-in Private Cloud Compute backend.
        case appStore
        /// The Developer ID DMG: no PCC backend.
        case developerID

        public init(privateCloudBackendPresent: Bool) {
            self = privateCloudBackendPresent ? .appStore : .developerID
        }
    }

    public enum Kind: String, Sendable, CaseIterable {
        case modelDownloads, webTools, updates, privateCloud
    }

    public struct Crossing: Identifiable, Equatable, Sendable {
        public let kind: Kind
        /// Off until the user turns it on (PCC); web search is a switch but on by default.
        public let optIn: Bool
        /// M1K3 itself makes the connection (updates ride the store, so they are not M1K3's).
        public let madeByApp: Bool
        /// "download the models you choose (brains, speech, voice)": completes "It goes online only to …".
        public let phrase: String
        /// Whether Settings carries a switch for it.
        public let hasSettingsSwitch: Bool

        public var id: String {
            kind.rawValue
        }
    }

    public static func crossings(for lane: Lane) -> [Crossing] {
        var list = [
            Crossing(
                kind: .modelDownloads, optIn: true, madeByApp: true,
                phrase: String(localized: "download the models you choose (brains, speech, voice)"),
                hasSettingsSwitch: false
            ),
            Crossing(
                kind: .webTools, optIn: false, madeByApp: true,
                phrase: String(localized: "search the web and look things up"), hasSettingsSwitch: true
            ),
            Crossing(
                kind: .updates, optIn: false, madeByApp: false,
                phrase: String(localized: "update"), hasSettingsSwitch: false
            ),
        ]
        if lane == .appStore {
            list.append(Crossing(
                kind: .privateCloud, optIn: true, madeByApp: true,
                phrase: String(localized: "use the optional Private Cloud Compute brain"), hasSettingsSwitch: true
            ))
        }
        return list
    }

    // MARK: - Downloads

    /// Where each download comes from. Exhaustive on purpose.
    public static func hosts(for kind: DownloadKind) -> [String] {
        switch kind {
        case .lil, .big, .pocket, .semanticMemory, .sharperEars: ["huggingface.co"]
        case .voice: ["huggingface.co", "github.com"]
        }
    }

    /// Every host a download can touch, sorted.
    public static var downloadHosts: [String] {
        Array(Set(DownloadKind.allCases.flatMap(hosts(for:)))).sorted()
    }

    // MARK: - In-app copy

    /// HelloView's privacy line (the line App Review reads first, #479): honest per lane.
    public static func helloPrivacyLine(for lane: Lane) -> String {
        let made = crossings(for: lane).filter(\.madeByApp)
        let switches = made.filter(\.hasSettingsSwitch)
        let goes = joined(made.map(\.phrase))
        let which = switches.map { $0.kind == .webTools ? "Web search" : "Private Cloud Compute" }
        let switchLine = which.count == 1
            ? String(localized: "\(which[0]) is a switch in Settings.")
            : String(localized: "\(joined(which)) are each a switch in Settings.")
        return String(localized: "Your local AI companion. Runs on this Mac — no account. It goes online only to \(goes).")
            + " " + switchLine
    }

    /// The Privacy pane's Tools footer under the web-search switch. "The one capability" is
    /// true only when no Private Cloud Compute rung exists (ADR 0006), and even then only beside downloads.
    public static func webSearchFootnote(for lane: Lane) -> String {
        let tail = String(localized: """
        every search and page read shows in the reply as it happens. Date, time, and system \
        tools stay local either way.
        """)
        switch lane {
        case .developerID:
            return String(localized: "Besides model downloads, the one capability that sends anything off this Mac: ") + tail
        case .appStore:
            return tail.prefix(1).uppercased() + tail.dropFirst()
        }
    }

    private static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
        }
    }
}
