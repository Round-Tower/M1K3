//
//  SettingsView.swift
//  M1K3App
//
//  The Settings window shell — five tabs, one file each under Settings/. Split
//  out of a single ~700-line Form (2026-06-06 → 2026-07-13, it had grown to
//  the ViewBuilder type-checker's budget) into: M1K3 (brain + reasoning +
//  companion + voice, in and out), You (about-you + memories + reading),
//  Privacy (web search / Spotlight / MCP — the product's promise told in one
//  place), General (startup + notifications + sound — app chrome, never
//  M1K3's mind), Advanced (embeddings / calls / generation stats / agent log
//  / status / weight import / diagnostics / licenses). Each pane owns its own
//  @AppStorage/@State; this file is purely composition. `AppEnvironment` and
//  `LaunchAtLogin` reach every pane via the `.environment(...)` M1K3App.swift
//  already attaches to the Settings scene — no re-injection needed here.
//
//  Signed: Kev + claude-fable-5, 2026-07-13, Confidence 0.85 (a straight move
//  — every footer/copy carried verbatim except the three Kev-approved cuts
//  documented at each pane; verify-by-launch as ever for SwiftUI moves).
//  Prior: Kev + claude-opus-4-8 (SettingsView.swift lineage, 2026-06-06).
//  Review: Kev + claude-fable-5, 2026-09-01 — an IA pass moved Reasoning
//  (General) and Voice input (Advanced) onto the M1K3 tab, next to Voice
//  output: one home for "how does it think" and "how does it sound/listen",
//  instead of three tabs for what's really one topic each. Confidence 0.85
//  (compiles + app builds; the tab-hop reduction is the intended win, feel
//  is a named ⌘R verify-owed like every SwiftUI move in this file family).
//  Review: Kev + claude-fable-5.1, 2026-09-07 — TabView gained a selection (`Pane`) so the screengrab harness can
//  open on Privacy for its privacy-label plate; every ordinary launch still opens on M1K3. Confidence now 0.9.
//

import M1K3Screengrab
import SwiftUI

struct SettingsView: View {
    enum Pane: Hashable { case m1k3, you, privacy, general, advanced }

    /// Opens on M1K3 as before; the screengrab harness lands on Privacy for its
    /// privacy-label plate (no-op without M1K3_SCREENGRAB=1).
    @State private var pane: Pane = ScreengrabHarness.current.showsPrivacyPane ? .privacy : .m1k3

    var body: some View {
        TabView(selection: $pane) {
            M1K3SettingsPane()
                .tabItem { Label("M1K3", systemImage: "brain") }
                .tag(Pane.m1k3)
            YouSettingsPane()
                .tabItem { Label("You", systemImage: "person.crop.circle") }
                .tag(Pane.you)
            PrivacySettingsPane()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(Pane.privacy)
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pane.general)
            AdvancedSettingsPane()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(Pane.advanced)
        }
        .frame(width: 480)
        .glassBackdrop()
    }
}
