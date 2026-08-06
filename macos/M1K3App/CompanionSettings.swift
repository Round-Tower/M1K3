//
//  CompanionSettings.swift
//  M1K3App
//
//  The avatar customization section of Settings — the face IS the product's
//  identity, so choosing it should show it. A LIVE preview (the real
//  AvatarSurface, honest to every knob below it) sits above glass face-cards;
//  the shading picker appears only when a 3D creature is chosen (it means
//  nothing for the pixel face / constellation). Replaces the old trio of plain
//  text Pickers + wall-of-text footer.
//
//  Own file: SettingsView's Form is at the type-checker budget, and the card
//  views are shared vocabulary with the onboarding cards (SelectionRadio).
//
//  Signed: Kev + claude-fable-5, 2026-07-02, Confidence 0.8 (structure compiles
//  + reuses proven pieces; the preview height, card row density and the
//  "Say hi" beat are verify-by-eye at ⌘R). Prior: SettingsView.companionSection
//  (Kev + claude-opus-4-8 lineage).
//

import M1K3Avatar
import SwiftUI

struct CompanionSettingsSection: View {
    let env: AppEnvironment

    @AppStorage(AppEnvironment.voiceCompanionKey) private var voiceCompanion = ""
    @AppStorage(AppEnvironment.avatarDisplayKey) private var avatarDisplay = AvatarDisplay.panel
    @AppStorage(AppEnvironment.companionShadingKey) private var companionShading =
        CompanionShadingStyle.off.rawValue

    /// One selectable face. The creature list self-extends: a new CompanionSpec
    /// with bundled assets appears here with no picker wiring (same isInstalled
    /// filter as ever).
    fileprivate struct FaceChoice: Identifiable {
        let id: String
        let name: String
    }

    private var choices: [FaceChoice] {
        [
            FaceChoice(id: "", name: "Pixel face"),
            FaceChoice(
                id: AppEnvironment.voiceCompanionConstellation,
                name: "Constellation"
            ),
        ] + CompanionSpec.all.filter(CompanionAssets.isInstalled).map {
            FaceChoice(id: $0.id, name: $0.displayName)
        }
    }

    private var creatureChosen: Bool {
        CompanionSpec.named(voiceCompanion) != nil
    }

    var body: some View {
        Section {
            preview
            facePicker

            Picker("Display", selection: $avatarDisplay) {
                ForEach(AvatarDisplay.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            caption("Panel above the chat, a full-window backdrop that recedes "
                + "while you read or type, or off.")

            // Shading is a property OF a creature's surface — meaningless for
            // the pixel face / constellation, so it only appears when it applies.
            if creatureChosen {
                Picker("Skin", selection: $companionShading) {
                    ForEach(CompanionShadingStyle.allCases) {
                        Text($0.displayName).tag($0.rawValue)
                    }
                }
                caption("Phosphor is a glowing rim that shifts with M1K3's state; "
                    + "Cel toon-bands the creature's own texture.")
            }
        } header: {
            Text("Companion")
        } footer: {
            caption("M1K3's face in the avatar panel and voice mode. "
                + "The menu-bar mark stays the pixel M either way.")
        }
    }

    /// The live face — the real AvatarSurface, so every choice below updates it
    /// immediately (face, skin, even a mid-conversation emotion). "Say hi" pokes
    /// a beat so the face demonstrably lives; the controller is shared, so the
    /// main window waves along — a feature, not a leak.
    private var preview: some View {
        AvatarSurface(env: env)
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 14))
            .overlay(alignment: .bottomTrailing) {
                Button("Say hi") { sayHi() }
                    .buttonStyle(.glass)
                    .padding(10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live preview of the chosen companion face")
    }

    /// A dropdown, not a card row (Kev, 2026-08-06): the creature roster
    /// outgrew the cards and their glyphs were noise — the live preview
    /// above is the picture; the menu only needs names.
    private var facePicker: some View {
        Picker("Face", selection: $voiceCompanion) {
            ForEach(choices) { choice in
                Text(choice.name).tag(choice.id)
            }
        }
        .accessibilityLabel("Companion face")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    /// A quick greeting beat on the shared controller, then back to idle —
    /// unless a real activity took over in the meantime (don't stomp a live
    /// thinking/speaking state when the sleep resumes).
    private func sayHi() {
        env.avatar.setEmotion(.excited)
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if env.avatar.state.activity == .idle {
                env.avatar.resetToIdle()
            }
        }
    }
}
