//
//  M1K3iOSApp.swift  (was: the 2026-07-06 derisk harness)
//  M1K3iOS / M1K3visionOS — the shipping shell's entry point
//
//  History: this file began as the on-device derisk harness — a minimal shell
//  that ran the real engine + the pixel-cube avatar on an iPhone 17 Pro to move
//  the port from "compiles" to "runs like M1K3" (both Mini and Lil verified on
//  device, 2026-07-06). It has since grown up into the real shared adaptive
//  shell: it builds the `AppCore` composition root and mounts `RootView` —
//  chat IS the app (a `NavigationStack` over `ChatScreen`; Memories/Documents/
//  Settings are pushes behind the toolbar gear since 2026-07-29) — over the
//  SAME package pipeline the Mac app ships. The Mac's `AppEnvironment` is
//  untouched.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.8 (compile-verified for
//  iOS + visionOS; on-device run is the Phase-B verify-owed — MLX needs Metal,
//  absent on the simulator). Prior: Kev + claude-fable-5 (the harness form).
//
//  Review: Kev + claude-fable-5.1, 2026-10-09 — injects `photoMemory` (caption memory) into the root. TDD_SKIP:
//  scene wiring.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — the Phosphor Fox (white lattice) is the house default via CompanionDefaults.registeredDefaults / houseCompanion (Kev, TestFlight 499). Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-12 — a true background ends a chat auto-speak session (no background audio mode).
//  Review: Kev + claude-opus-5.5, 2026-10-29 — #750's session mark follows the scene: open when active (at boot too, if
//  already active), closed on a true background, so a crash or memory kill in front is noticed by the next launch.
//  Review: Kev + claude-opus-5.5, 2026-10-29 (pre-push review fold) — the app owns the guard and marks before AppCore
//  builds (a live applicationState read, not the task's scenePhase copy); a mark found first is held until the core
//  exists; the background clear runs before the brain is shed. Confidence 0.75.
//  Review: Kev + claude-fable-5.2, 2026-11-11 — a true background also stops an on-device answer in flight and the
//  speech properly (`stopForBackground`), before the shed. Drilled on the iPhone 17 Pro: without it, returning mid-answer
//  on Lil got the app killed for memory. Confidence 0.8 (see BackgroundExitPolicy; the drill is in the PR).
//  Review: Kev + claude-opus-5.5, 2026-11-16 — coming to the front ends a lingering Live Activity card
//  (`turnActivity.appBecameActive`). Compile-checked; owes a try on a phone.
//  Review: Kev + claude-opus-5.5, 2026-11-16 — `.inactive` starts the Live Activity card for a turn in flight
//  (Kev's phone: a 6 s Mini turn never got one, and a card cannot start from the background).
//  Review: Kev + claude-opus-5.5, 2026-11-16 (review fold) — the notification delegate installs in `init`, and the
//  leaving-card starts only when the previous phase was .active (not on the return path).
//  Review: Kev + claude-opus-5.5, 2026-11-16 (#858) — `.inactive` stops an on-device answer before the background lands, while the GPU is still allowed. Confidence 0.7; owes a phone check (see BackgroundExitPolicy).
//  Review: Kev + claude-opus-5.5, 2026-11-26 — voice behind the lock: `.background` keeps a live conversation
//  (VoiceBehindLockPolicy) instead of leaving voice mode, `.inactive` puts its face on the Lock Screen, `.active`
//  brings the slot, mic and voice back before the re-warm. Confidence 0.7: the phone run is the proof.

import M1K3Avatar
import M1K3Diagnostics
import SwiftUI
import UIKit

@main
struct M1K3iOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var core: AppCore?
    @State private var bootError: String?
    /// Did the last session close cleanly? (#750) Owned here, like the Mac's delegate owns its
    /// guard, so the mark is set before AppCore builds: a crash while building still leaves it.
    @State private var sessionGuard = SessionGuard(
        storage: UserDefaults.standard, inert: AppCore.sessionGuardInert
    )
    /// A standing mark found before AppCore existed, handed over once it does.
    @State private var pendingUnclean: Date?

    init() {
        BundledFonts.register() // Silkscreen — the pixel wordmark face.
        // Before the core exists (it is built asynchronously): a cold-launch tap on a turn notice must reach it.
        TurnNoticeDelegate.install()
        // The Phosphor Fox (white baked lattice, no shader) is the house default on
        // every surface, Mac and phone alike. Registered, not written: an explicit
        // persisted choice (any face, including the pixel face's "") always wins, and
        // if the assets were ever absent the resolver falls back to the pixel face,
        // never blank.
        UserDefaults.standard.register(defaults: CompanionDefaults.registeredDefaults)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let core {
                    RootView(startOnboarded: core.hasChosenBrain)
                        .environment(core)
                        .environment(\.photoMemory, core.photoMemory)
                } else if let bootError {
                    bootErrorView(bootError)
                } else {
                    bootLoadingView.task { boot() }
                }
            }
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { previous, phase in
                // Shed MLX weights on a true background (jetsam hygiene), re-warm on
                // return. `.inactive` (Control Center, an alert) never sheds the model, so a transient
                // interruption doesn't churn it; it starts the Live Activity card and stops an on-device answer (below).
                switch phase {
                case .inactive:
                    // ONE case, in this order. (1) The Live Activity card starts while we are still foreground (an
                    // answer asked and then left is mostly under 8 s, and no card can start once we are gone). Only
                    // from .active: the way BACK (.background → .inactive → .active) must not start a card. A system
                    // sheet mid-turn can still start one that the next .active takes down: accepted.
                    if previous == .active { core?.turnActivityGoingInactive() }
                    // A voice conversation about to go behind the lock puts its face on the Lock Screen, for the
                    // same reason: no card can start once we are gone.
                    if previous == .active { core?.voiceBehindLockGoingInactive() }
                    // (2) Then the on-device stop, before the background so a generation step drains while the GPU
                    // is still allowed (#858). It tells the card "Paused" first, then stops (AppCore). Unconditional
                    // on `previous`: on the way back nothing is running (it was stopped), so it is a no-op.
                    core?.stopTurnForInactive()
                case .background:
                    // What iOS does to a backgrounded app is no snag (#750). First, so a
                    // memory kill while the brain is shed below is not one either.
                    sessionGuard.end()
                    // A voice conversation keeps going behind the lock (VoiceBehindLockPolicy: the switch is on and
                    // someone off the GPU can answer). Otherwise voice mode is left cleanly BEFORE the shed, so the
                    // loop never sees a dead mic. Decided first, while the chosen brain is still what it was.
                    let keptVoice = core?.voiceBehindLockBrain
                    if keptVoice == nil { core?.exitVoiceMode() }
                    // No background GPU: an answer being made on this device stops, BEFORE the shed, or the turn
                    // keeps the brain alive and the return loads a second copy (BackgroundExitPolicy). The speech
                    // stops too, unless a conversation goes behind the lock in the system voice, which can finish.
                    let keepsSpeaking = keptVoice != nil && core?.selectedVoiceTier == .builtin
                    core?.stopForBackground(keepsSpeaking: keepsSpeaking)
                    core?.releaseForBackground()
                    if let keptVoice { core?.enterVoiceBehindLock(keptVoice) }
                case .active:
                    // Back from behind the lock: the slot, the mic and the voice come back BEFORE the re-warm.
                    core?.voiceBehindLockReturning()
                    markSessionActive()
                    core?.turnActivity.appBecameActive()
                    core?.warmForForeground()
                @unknown default: break
                }
            }
        }
    }

    @MainActor
    private func boot() {
        // Launched into the foreground: this session is open (#750), marked before the heavy
        // build. A live read, not `scenePhase` (the task's copy can be stale); a background
        // launch waits for its first .active.
        if UIApplication.shared.applicationState == .active { markSessionActive() }
        do {
            let built = try AppCore()
            core = built
            if let pendingUnclean {
                built.noteUncleanExit(openedAt: pendingUnclean)
                self.pendingUnclean = nil
            }
        } catch {
            bootError = error.localizedDescription
        }
    }

    /// Mark this session open. The process's first mark reports the last session if it never
    /// closed: straight to AppCore, or held until boot has built one.
    @MainActor
    private func markSessionActive() {
        guard let since = sessionGuard.begin() else { return }
        if let core { core.noteUncleanExit(openedAt: since) } else { pendingUnclean = since }
    }

    private var bootLoadingView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView().controlSize(.large).tint(.white)
        }
    }

    private func bootErrorView(_ message: String) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ContentUnavailableView(
                "M1K3 couldn't start",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
}
