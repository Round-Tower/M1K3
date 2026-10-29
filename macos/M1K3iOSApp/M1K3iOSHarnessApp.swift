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
            .onChange(of: scenePhase) { _, phase in
                // Shed MLX weights on a true background (jetsam hygiene), re-warm on
                // return. `.inactive` (notification banner / Control Center) is
                // deliberately ignored so transient interruptions don't churn the model.
                switch phase {
                case .background:
                    // What iOS does to a backgrounded app is no snag (#750). First, so a
                    // memory kill while the brain is shed below is not one either.
                    sessionGuard.end()
                    // Voice mode can't survive a true background (the mic engine
                    // and audio session are torn down by the OS) — leave cleanly
                    // BEFORE shedding the brain, so the loop never sees a dead mic.
                    core?.exitVoiceMode()
                    core?.cancelAutoSpeak() // no background audio: a half-read answer just stops
                    core?.releaseForBackground()
                case .active:
                    markSessionActive()
                    core?.warmForForeground()
                default: break
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
