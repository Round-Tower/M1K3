//
//  RootView.swift
//  M1K3iOS / M1K3visionOS
//
//  The adaptive shell: a first-run onboarding gate, then chat AS the app — one
//  NavigationStack rooted on ChatScreen. The bottom tab bar is gone (2026-07-29,
//  Kev's call): Memories and Documents are workspace rooms behind Settings, and
//  Settings itself is a toolbar push from chat. A chat app's home is the
//  conversation, not a switcher — and on visionOS this also retires the tab
//  ornament that rendered as dark squares (the V0 finding, closed by removal).
//
//  Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.8. Prior: Kev +
//  claude-fable-5 (the TabView form).
//  Review: Kev + claude-fable-5, 2026-07-29 — TabView(.sidebarAdaptable) →
//  NavigationStack{ChatScreen}; navigation moved into toolbars.
//  Review: Kev + claude-opus-5-5, 2026-10-03 — the stack owns a typed path so the screengrab harness can push
//  a plate's screen (`ScreengrabHarness.phoneRoute`); every ordinary link is still view-destination. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-12 — TestFlight 505, "Lil Waking seems to hang at 0%": the screen stays on while a
//  brain downloads. The Hub downloads in a foreground session, so an auto-lock suspends it and the retry restarts the file
//  from zero. From the root, so pushing Settings over the chat doesn't drop it. Confidence 0.75 (verify on the phone).
//  Review: Kev + claude-opus-5.5, 2026-10-12 — not while iOS carries the download (a continued-processing task): then the
//  screen may sleep and the system shows the progress. Confidence 0.75.
//  Review: Kev + claude-opus-5-5, 2026-10-14 — onOpenURL: an `m1k3://` link (Halloween's event, #603)
//  pops to the chat root. Confidence 0.8 (verify-by-launch).
//  Review: Kev + claude-opus-5.5, 2026-10-29 — #750: the chat screen carries SnagNoteHost, outside ChatScreen's own
//  modifier chain. Confidence unchanged.
//  Review: Kev + claude-opus-5-5, 2026-11-23 — share to M1K3 (#893 C): onOpenURL moves to the root Group, so a file
//  shared at cold launch or during onboarding is caught and held (`sharedFiles`) until the chat screen stages it;
//  `SharedFileIntake.classify` tells a file from an `m1k3://` link. Confidence 0.8 (verify on the phone).
//

import M1K3Inference
import M1K3Screengrab
import SwiftUI

struct RootView: View {
    @Environment(AppCore.self) private var core
    @State private var onboarded: Bool
    /// Only the screengrab harness writes this (ChatScreen, once the brain is ready).
    @State private var screengrabPath: [ScreengrabRoute] = []
    /// Files shared to M1K3 (AirDrop, Files, Share → Open in), held until the chat screen stages them. Lives here,
    /// above the onboarding gate, so a file shared on first run or at cold launch waits instead of being lost.
    @State private var sharedFiles: [URL] = []

    init(startOnboarded: Bool) {
        _onboarded = State(initialValue: startOnboarded)
    }

    var body: some View {
        Group {
            if onboarded {
                NavigationStack(path: $screengrabPath) {
                    ChatScreen(screengrabPath: $screengrabPath, sharedFiles: $sharedFiles).modifier(SnagNoteHost())
                }
                .preferredColorScheme(.dark)
            } else {
                OnboardingScreen {
                    // Sole writer of the first-run gate: selectBrain can no-op
                    // early-return (picking Mini at idle) before it could persist this,
                    // so onboarding must record its own completion or it repeats every
                    // launch (startOnboarded reads hasChosenBrain at init).
                    UserDefaults.standard.set(true, forKey: AppCore.hasChosenBrainKey)
                    withAnimation { onboarded = true }
                }
                .transition(.opacity)
            }
        }
        .onOpenURL { url in
            switch SharedFileIntake.classify(url) {
            case .deepLink:
                // Every `m1k3://` link (event or not) is the chat screen, the stack's root.
                screengrabPath = []
            case let .file(file):
                // Staged (never sent) by the chat screen, after onboarding if it isn't done yet.
                sharedFiles.append(file)
                screengrabPath = []
            case .ignore:
                break
            }
        }
        #if os(iOS)
        // An auto-lock suspends a foreground download (the retry restarts the file from zero). When iOS carries it
        // (a continued-processing task) the screen may sleep: the system keeps it going and shows the progress.
        .onChange(of: core.isDownloadingBrain && !core.brainDownloadContinues, initial: true) { _, downloading in
            UIApplication.shared.isIdleTimerDisabled = downloading
        }
        #endif
    }
}
