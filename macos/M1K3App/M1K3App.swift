//
//  M1K3App.swift
//  M1K3App
//
//  Entry point. The composition root (AppEnvironment) opens the on-disk store, so
//  construction can fail — the AppDelegate builds it once at launch and the Scene
//  shows a clear failure surface rather than crashing if the container isn't writable.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.85 — moved AppEnvironment
//  ownership from the main-window `.task` to AppDelegate.applicationDidFinishLaunching
//  (built + registered + warmed at launch, window-independent), so a background App
//  Intent launch can reach the warm model with no window. AppDelegate is now
//  @MainActor + ObservableObject and publishes `environment`/`startupError`; the
//  Scene reads `appDelegate.environment`. Self-test path unchanged (guarded).

import AppKit
import M1K3Avatar
import M1K3Launch
import os
import SwiftUI

@main
struct M1K3App: App {
    /// Stable id so the menu-bar item can re-open the main window after it's closed.
    static let mainWindowID = "main"

    /// When true, the first-run gate shows BrainPickerView (Settings → "Change
    /// brain…" / the toolbar switcher's download route) instead of HelloView:
    /// a brain re-pick, finishing on wake, never replaying the hello. Kept here
    /// (not on AppEnvironment) so the Scene and Settings share it without
    /// reaching into the store; reset to false when the picker completes.
    static let onboardingStartAtBrainKey = "onboarding.startAtBrain"

    /// Sets the activation policy (Dock icon vs accessory) before the first
    /// window appears, so a menu-bar-only launch never flashes a Dock icon.
    /// Owns + publishes the AppEnvironment (built at launch, window-independent) so
    /// App Intents can reach it; the Scene tracks `appDelegate.environment`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Launch-at-login is app-level (not on AppEnvironment) so it works even if
    /// the store fails to open — the toggle and menu must function regardless.
    @State private var launchAtLogin = LaunchAtLogin(item: SMAppServiceLoginItem())
    /// First-run gate: show "choose your brain" until a brain has been picked.
    @AppStorage(AppEnvironment.hasChosenBrainKey) private var hasChosenBrain = false
    /// Brain-only re-pick flag: when set by Settings → "Change brain…", the
    /// gate shows BrainPickerView, which finishes on wake.
    @AppStorage(Self.onboardingStartAtBrainKey) private var onboardingStartAtBrain = false
    /// Whether to live in the menu bar only (no Dock icon, no window forced
    /// open at launch). The menu-bar mark is always the pixel M (see
    /// `MenuBarLabel` below) — the glyph picker was cut from Settings
    /// 2026-07-13 (Kev-approved).
    @AppStorage(StartupPreferences.menuBarOnlyKey) private var menuBarOnly = false

    init() {
        BundledFonts.register()
    }

    var body: some Scene {
        // A single-instance `Window`, NOT `WindowGroup`: M1K3 is one companion
        // window, and `openWindow(id:)` from the menu must SUMMON the existing
        // window — `WindowGroup` would spawn a fresh one on every click.
        Window("M1K3", id: Self.mainWindowID) {
            Group {
                if SelfTest.isRequested {
                    ProgressView("Running self-test…")
                        .frame(minWidth: 360, minHeight: 200)
                        .task {
                            await SelfTest.run()
                            exit(0)
                        }
                } else if let env = appDelegate.environment {
                    // Three-way first-run gate (SelfTest branch above MUST stay
                    // first — headless runs land on fresh containers where these
                    // keys are unset). Order below matters too: a pending
                    // brain-repick deep link (`onboardingStartAtBrain`) outranks
                    // the HelloView fallback, so a user who deep-linked then
                    // relaunched lands back in the picker, not the hello.
                    // These closures are the ONLY writers of `hasChosenBrain =
                    // true` — selectBrain deliberately doesn't touch it (a write
                    // mid-download would swap the view out from under its own
                    // progress UI).
                    if hasChosenBrain {
                        ContentView()
                            .environment(env)
                    } else if onboardingStartAtBrain {
                        BrainPickerView {
                            hasChosenBrain = true
                            onboardingStartAtBrain = false
                        }
                        .environment(env)
                    } else {
                        HelloView {
                            hasChosenBrain = true
                        }
                        .environment(env)
                    }
                } else if let startupError = appDelegate.startupError {
                    StartupFailureView(message: startupError)
                } else {
                    ProgressView("M1K3…")
                        .controlSize(.large)
                        .frame(minWidth: 560, minHeight: 480)
                }
            }
            // No forced colour scheme: M1K3 follows the system appearance. The
            // surface is pure adaptive Liquid Glass (GlassBackground) that refracts
            // the desktop and reads correctly in both light and dark — so the old
            // painted-dark / white-sheet mismatch can't happen in either mode.
            // Signed: Kev + claude-opus-4-8, 2026-06-08, Confidence 0.75, Prior: Unknown
            // (AppEnvironment is built at launch by AppDelegate — window-independent,
            // so a background App Intent launch can reach it.)
        }
        .windowResizability(.contentSize)
        // Hidden title bar: drop the "M1K3" window title so the glass runs
        // uninterrupted to the top. Traffic lights + toolbar actions remain; the
        // app's identity is the conversation, not a chrome label.
        .windowStyle(.hiddenTitleBar)
        // Menu-bar-only: don't auto-present the window at launch (incl. login) —
        // M1K3 starts quietly in the bar and the menu's "Open M1K3" summons it.
        // Routed through StartupVisibility so the decision lives in one tested place.
        .defaultLaunchBehavior(
            StartupVisibility(menuBarOnly: menuBarOnly).suppressesLaunchWindow ? .suppressed : .automatic
        )
        .commands {
            ConstellationCommands()
            AgentLogCommands()
        }

        // The 3D memory constellation — memories as motes, edges as threads, the
        // field accreting as the store grows. A single-instance Window summoned
        // from the Window menu; rebuilds its snapshot from the live store each open.
        Window("Memory Constellation", id: Self.constellationWindowID) {
            ConstellationWindowContent(env: appDelegate.environment)
        }
        .windowResizability(.contentSize)

        // The Agent Interaction Log — a scrollable review of every MCP tool
        // call captured while the opt-in Settings toggle is on (off by
        // default). Single-instance Window, summoned from the Window menu.
        Window("Agent Log", id: Self.agentLogWindowID) {
            AgentLogWindowContent(env: appDelegate.environment)
        }
        .windowResizability(.contentSize)

        // The Heartbeat became a sidebar DESTINATION on 2026-08-19
        // (HeartbeatScreen in ContentView's detail switch) — its summoned
        // Window retired with the promotion; other scenes reach it via
        // env.pendingSidebarRequest.

        // Native macOS Settings scene — opened with ⌘, (or the toolbar gear via
        // SettingsLink), in its own window with the system title bar, instead of
        // the iOS-style modal sheet it used to be. Shares the one AppEnvironment;
        // the env-nil branch only shows in the first beat before startup completes.
        // Signed: Kev + claude-opus-4-8, 2026-06-08, Confidence 0.8, Prior: Unknown
        Settings {
            Group {
                if let env = appDelegate.environment {
                    SettingsView()
                        .environment(env)
                        .environment(launchAtLogin)
                } else {
                    Text("M1K3 is still waking up…")
                        .foregroundStyle(.secondary)
                        .frame(width: 480, height: 220)
                }
            }
        }

        // The always-resident status-bar item. Its presence alone keeps M1K3
        // running after the window is closed — the menu-bar companion. A rich glass
        // popover (ask without opening the window) behind a state-reflective pixel
        // glyph (calm idle, pulsing while thinking, red while recording, glow while
        // speaking).
        // Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.7, Prior: Unknown
        MenuBarExtra {
            MenuBarPopover(env: appDelegate.environment)
        } label: {
            MenuBarLabel(env: appDelegate.environment, glyphStyle: .pixelM)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the composition root. Two launch jobs:
///   1. Set the menu-bar-only activation policy BEFORE the first window shows, so
///      no Dock icon flashes on a quiet launch (read straight from UserDefaults —
///      the delegate runs before SwiftUI state is available).
///   2. Build + register + warm the `AppEnvironment` at launch — independent of any
///      window. M1K3 is menu-bar-resident (launch-at-login), and an App Intent's
///      perform() runs outside SwiftUI's @Environment, so the environment must
///      exist (and the brain be warming) even when no window is presented. That's
///      what makes a quiet, background Siri/Shortcuts ask answer without opening
///      the app. Published so the Scene tracks it (env nil → "Waking M1K3…").
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var environment: AppEnvironment?
    @Published private(set) var startupError: String?

    func applicationWillFinishLaunching(_: Notification) {
        // Before any MLX use: the quit-during-generation guard (MLXExitGuard
        // header has the crash story). Normal errors stay fail-loud.
        MLXExitGuard.install()
        // The phosphor Fox is the house default (Kev, 2026-08-06: "pretty
        // awesome — default standard"). Registered defaults, not writes: an
        // explicit persisted choice (any face, any skin — including pixel
        // face's "") always wins; only the never-touched majority resolve
        // here. If Fox's assets are ever absent the resolver's unknown-id
        // fallback still lands on the pixel face — never a blank surface.
        UserDefaults.standard.register(defaults: [
            CompanionDefaults.companionKey: "Fox",
            CompanionDefaults.shadingStyleKey: CompanionShadingStyle.phosphor.rawValue,
        ])
        let menuBarOnly = UserDefaults.standard.bool(forKey: StartupPreferences.menuBarOnlyKey)
        if StartupVisibility(menuBarOnly: menuBarOnly).hidesDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static let launchLog = Logger(subsystem: "app.m1k3", category: "launch")

    /// First line of every session: which build emitted the lines that follow.
    /// Without it a `log stream` window or a user's Console capture has no anchor
    /// to the version/build under test. `GitCommitSHA` is logged when injected at
    /// build time (Info.plist key), omitted otherwise.
    private static func logLaunchStamp() {
        func info(_ key: String) -> String {
            Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
        }
        let version = info("CFBundleShortVersionString")
        let build = info("CFBundleVersion")
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let sha = Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String ?? "—"
        launchLog.notice("launch: M1K3 \(version, privacy: .public) (\(build, privacy: .public)) sha=\(sha, privacy: .public) on \(os, privacy: .public)")
    }

    /// Terminate is always allowed — this only STAMPS that termination has
    /// begun, so an MLX eval interrupted by the coming exit() logs and parks
    /// instead of fatalError-ing over a clean quit (MLXExitGuard).
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        MLXExitGuard.markTerminating()
        return .terminateNow
    }

    func applicationDidFinishLaunching(_: Notification) {
        Self.logLaunchStamp()
        // The self-test path drives its own composition; don't double-build here.
        guard !SelfTest.isRequested else { return }
        // Build off the launch beat (async) so first paint isn't blocked, but at
        // app scope, not window scope — a background intent launch has no window.
        Task { @MainActor in
            do {
                let env = try AppEnvironment()
                environment = env
                AppEnvironment.registerShared(env)
                // Warm the restored brain now so a resident-but-windowless M1K3 can
                // answer a quiet ask. Idempotent with ContentView's own warm-up.
                await env.warmUpSelectedBrainOnLaunch()
            } catch {
                startupError = error.localizedDescription
            }
        }
    }
}

private struct StartupFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("M1K3 couldn’t start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
        .frame(minWidth: 560, minHeight: 480)
    }
}
