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
//

import SwiftUI

struct RootView: View {
    @Environment(AppCore.self) private var core
    @State private var onboarded: Bool

    init(startOnboarded: Bool) {
        _onboarded = State(initialValue: startOnboarded)
    }

    var body: some View {
        if onboarded {
            NavigationStack { ChatScreen() }
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
}
