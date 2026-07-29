//
//  M1K3iOSApp.swift  (was: the 2026-07-06 derisk harness)
//  M1K3iOS / M1K3visionOS — the shipping shell's entry point
//
//  History: this file began as the on-device derisk harness — a minimal shell
//  that ran the real engine + the pixel-cube avatar on an iPhone 17 Pro to move
//  the port from "compiles" to "runs like M1K3" (both Mini and Lil verified on
//  device, 2026-07-06). It has since grown up into the real shared adaptive
//  shell: it builds the `AppCore` composition root and mounts the tabbed
//  `RootView` (Chat / Memories / Documents / Settings) over the SAME package
//  pipeline the Mac app ships. The Mac's `AppEnvironment` is untouched.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.8 (compile-verified for
//  iOS + visionOS; on-device run is the Phase-B verify-owed — MLX needs Metal,
//  absent on the simulator). Prior: Kev + claude-fable-5 (the harness form).
//

import SwiftUI

@main
struct M1K3iOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var core: AppCore?
    @State private var bootError: String?

    init() {
        BundledFonts.register() // Silkscreen — the pixel wordmark face.
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let core {
                    RootView(startOnboarded: core.hasChosenBrain)
                        .environment(core)
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
                    // Voice mode can't survive a true background (the mic engine
                    // and audio session are torn down by the OS) — leave cleanly
                    // BEFORE shedding the brain, so the loop never sees a dead mic.
                    core?.exitVoiceMode()
                    core?.releaseForBackground()
                case .active: core?.warmForForeground()
                default: break
                }
            }
        }
    }

    @MainActor
    private func boot() {
        do {
            core = try AppCore()
        } catch {
            bootError = error.localizedDescription
        }
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
