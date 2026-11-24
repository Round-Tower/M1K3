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
//  Review: Kev + claude-opus-5-5, 2026-11-23 (#895 third pass) — Inbox leftovers are swept here when the app goes to
//  the background, sparing `sharedFiles`; never while staging (a batch AirDrop's siblings). Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-11-23 (share to M1K3, slice 2) — the root claims the share extension's drops
//  from the App Group inbox (`ShareInbox.claimAll`) at launch, whenever the app becomes active, and on the extension's
//  Darwin ping (an iPad already showing M1K3 beside Safari): words go to `sharedDrafts`, files to `sharedFiles`, both
//  held above onboarding like slice 1. The background sweep also clears held drops nothing waits on. On visionOS
//  there is no group, so the claim finds nothing. Confidence 0.75 (Simulator-built; the device hand-off is owed).
//  Review: Kev + claude-opus-5-5, 2026-11-23 (pre-push review fold) — claim then kill lost the share (the claim deleted
//  the drop, leaving it only in @State and tmp). The root now holds whole drops (`sharedDrops`) read in place by
//  `ShareInbox.pending`, dedupes a second claim by name (`seenDrops`), and never deletes: ChatScreen discards a drop
//  once staged, so a jetsam mid-onboarding re-finds it on the next launch. The holding folder and its sweep are gone.
//  Confidence 0.8.
//

import M1K3Inference
import M1K3Screengrab
import M1K3ShareInbox
import notify
import SwiftUI

struct RootView: View {
    @Environment(AppCore.self) private var core
    @State private var onboarded: Bool
    /// Only the screengrab harness writes this (ChatScreen, once the brain is ready).
    @State private var screengrabPath: [ScreengrabRoute] = []
    /// Files shared to M1K3 (AirDrop, Files, Share → Open in), held until the chat screen stages them. Lives here,
    /// above the onboarding gate, so a file shared on first run or at cold launch waits instead of being lost.
    @State private var sharedFiles: [URL] = []
    /// Shares from another app's share sheet (words and files), held like `sharedFiles` until the chat screen stages
    /// them. Never sent. Each stays in the App Group container until then, so a kill before staging loses nothing.
    @State private var sharedDrops: [ShareInbox.Drop] = []
    /// Drop names already claimed in this run (waiting or staged): a second claim never stages one twice.
    @State private var seenDrops: Set<String> = []
    @Environment(\.scenePhase) private var scenePhase

    init(startOnboarded: Bool) {
        _onboarded = State(initialValue: startOnboarded)
    }

    var body: some View {
        Group {
            if onboarded {
                NavigationStack(path: $screengrabPath) {
                    ChatScreen(screengrabPath: $screengrabPath, sharedFiles: $sharedFiles, sharedDrops: $sharedDrops)
                        .modifier(SnagNoteHost())
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { sweepInboxLeftovers() }
            // Back from the app the person shared in: take what the share extension dropped.
            if phase == .active { claimShares() }
        }
        // At launch, then whenever the extension pings (M1K3 already on screen, beside the sharing app on an iPad).
        .task {
            claimShares()
            for await _ in Self.shareDrops() {
                claimShares()
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

extension RootView {
    /// Inbox copies no one will stage (the app was killed mid-onboarding, say), swept when the app leaves the screen:
    /// by then every URL of a batch share has arrived, and anything still waiting to be staged is kept (#895).
    private func sweepInboxLeftovers() {
        let inbox = URL.documentsDirectory.appending(path: "Inbox")
        let listed = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        for url in SharedFileIntake.inboxLeftovers(listed, waiting: sharedFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Takes what the share extension dropped into the App Group, oldest first, and pops to the chat. It reads the
    /// drops where they lie and deletes nothing: ChatScreen discards a drop once it is staged, so a kill in between
    /// (a jetsam mid-onboarding) finds it again on the next launch. A drop already claimed this run is skipped by name.
    /// Expired drops are deleted unread (`pending`). Nothing is sent: ChatScreen only stages.
    private func claimShares() {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareInbox.appGroup)
        else { return }
        let inbox = group.appending(path: ShareInbox.inboxFolderName)
        let fresh = ShareInbox.unseen(ShareInbox.pending(inbox: inbox), seen: seenDrops)
        guard !fresh.isEmpty else { return }
        seenDrops.formUnion(fresh.map(\.name))
        sharedDrops.append(contentsOf: fresh)
        screengrabPath = []
    }

    /// The share extension's "a drop landed" ping (a Darwin notification: no payload, no capability), as a stream.
    /// Any process may post the name; the worst a stray post does is one extra claim, which finds nothing new.
    private static func shareDrops() -> AsyncStream<Void> {
        AsyncStream { continuation in
            var token: Int32 = 0
            let status = notify_register_dispatch(ShareInbox.droppedNotification, &token, .main) { _ in
                continuation.yield()
            }
            guard status == NOTIFY_STATUS_OK else {
                continuation.finish()
                return
            }
            let registered = token
            continuation.onTermination = { _ in notify_cancel(registered) }
        }
    }
}
