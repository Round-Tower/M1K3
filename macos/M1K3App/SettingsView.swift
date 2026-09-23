//
//  SettingsView.swift
//  M1K3App
//
//  Settings as a SCREEN in the main window (2026-09-23, Kev: "not a pop-up
//  modal, a screen in its own right"): a sidebar destination like Memories or
//  the Heartbeat, reached from the sidebar's pinned Settings button, ⌘, and
//  every "Open Settings" link. The five panes are unchanged — M1K3 (brain,
//  reasoning, companion, voice), You, Privacy, General, Advanced — and still
//  own their own @AppStorage/@State; this file is the shell around them:
//
//    • an identity card (the app icon, who's thinking, what version) over a
//      live Game of Life field — the brand's "alive, quietly" texture;
//    • a row of pane chips in place of the Settings window's toolbar tabs;
//    • the selected pane's grouped Form, width-capped and centred so a wide
//      window reads like a page, not a spreadsheet.
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
//  Review: Kev + claude-opus-5-5, 2026-09-23 — the Settings WINDOW became a main-window
//  screen (Toplify-style reference from Kev): identity card over a LifeBackdrop, pane
//  chips, width-capped Form. The pane survives navigating away (SceneStorage); the
//  harness still lands on Privacy. Confidence 0.8 (builds; feel is verify-by-launch).
//

import M1K3Screengrab
import SwiftUI

struct SettingsView: View {
    enum Pane: String, CaseIterable, Hashable {
        case m1k3, you, privacy, general, advanced

        var title: String {
            switch self {
            case .m1k3: "M1K3"
            case .you: "You"
            case .privacy: "Privacy"
            case .general: "General"
            case .advanced: "Advanced"
            }
        }

        var systemImage: String {
            switch self {
            case .m1k3: "brain"
            case .you: "person.crop.circle"
            case .privacy: "hand.raised"
            case .general: "gearshape"
            case .advanced: "wrench.and.screwdriver"
            }
        }
    }

    /// The widest the page grows; past this, margins, not longer lines.
    static let pageMaxWidth: CGFloat = 860
    /// The header's side margin: the grouped Form's own card inset on macOS 26,
    /// measured, so the identity card and the section cards share their edges.
    static let pageMargin: CGFloat = 78

    @Environment(AppEnvironment.self) private var env
    /// Opens on M1K3 and remembers the last pane while the window lives.
    @SceneStorage("settings.pane") private var paneRaw = Pane.m1k3.rawValue

    private var pane: Pane {
        Pane(rawValue: paneRaw) ?? .m1k3
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                identityCard
                paneChips
            }
            .padding(.horizontal, Self.pageMargin)
            .frame(maxWidth: Self.pageMaxWidth)
            .padding(.top, 14)
            .padding(.bottom, 4)

            paneContent
                .frame(maxWidth: Self.pageMaxWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Settings")
        .onAppear {
            // The screengrab harness's privacy-label + Brain-at-Home plates.
            if ScreengrabHarness.current.showsPrivacyPane { paneRaw = Pane.privacy.rawValue }
        }
    }

    // MARK: - Identity card

    private var identityCard: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 60, height: 60)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("M1K3")
                    .font(.pixel(24))
                    .kerning(2)
                Text("\(env.selectedBrain.displayName) is thinking · everything stays on this Mac")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(Self.versionLabel)
                .font(.callout.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.background.secondary)
                .overlay {
                    LifeBackdrop(pitch: 15, strength: 0.8)
                        .mask(
                            LinearGradient(
                                colors: [.black.opacity(0.2), .black],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
        .accessibilityElement(children: .combine)
    }

    private static var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "v\($0)" } ?? "dev"
    }

    // MARK: - Pane chips

    private var paneChips: some View {
        HStack(spacing: 8) {
            ForEach(Pane.allCases, id: \.self) { candidate in
                let selected = candidate == pane
                Button {
                    paneRaw = candidate.rawValue
                } label: {
                    Label(candidate.title, systemImage: candidate.systemImage)
                        .font(.body.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background {
                            Capsule().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help("\(candidate.title) settings")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - The pane

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .m1k3: M1K3SettingsPane()
        case .you: YouSettingsPane()
        case .privacy: PrivacySettingsPane()
        case .general: GeneralSettingsPane()
        case .advanced: AdvancedSettingsPane()
        }
    }
}

/// A settings section's title: an icon in a tinted circle and a readable
/// title — the grouped Form's cards get a face instead of a small caps label.
struct SettingsHeader: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.tint.opacity(0.15)))
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}
