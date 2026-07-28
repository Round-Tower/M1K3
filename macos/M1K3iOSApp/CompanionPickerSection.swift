//
//  CompanionPickerSection.swift
//  M1K3iOS / M1K3visionOS
//
//  The avatar-customisation section of Settings — the iOS sibling of the Mac's
//  CompanionSettings. The face IS the product's identity, so choosing it shows it:
//  a LIVE preview (the real AvatarSurface, honest to every choice below it) sits
//  above a grid of glass face-cards. The skin (shading) picker appears only when a
//  3D creature is chosen — it means nothing for the pixel face.
//
//  The creature list self-extends: a new CompanionSpec with bundled assets appears
//  here with no picker wiring (the same isInstalled filter the Mac uses). The
//  constellation option is Mac-only for now, so it isn't offered here.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-28, Confidence 0.8 (composition of the
//  shared AvatarSurface + package CompanionSpec catalogue; the live creature render
//  is verify-by-launch on device — the simulator has no Metal). Prior: none (new
//  file, patterned on M1K3App/CompanionSettings.swift).
//

import M1K3Avatar
import SwiftUI

struct CompanionPickerSection: View {
    @Environment(AppCore.self) private var core
    @AppStorage(CompanionDefaults.companionKey) private var companion = ""
    @AppStorage(CompanionDefaults.shadingStyleKey) private var shadingRaw =
        CompanionShadingStyle.off.rawValue

    /// One selectable face. `glyph` nil = the pixel-M brand mark.
    private struct FaceChoice: Identifiable {
        let id: String
        let name: String
        let glyph: String?
    }

    private var choices: [FaceChoice] {
        [FaceChoice(id: "", name: "Pixel face", glyph: nil)]
            + CompanionSpec.all.filter(CompanionAssets.isInstalled).map {
                FaceChoice(id: $0.id, name: $0.displayName, glyph: "pawprint.fill")
            }
    }

    private var creatureChosen: Bool {
        CompanionSpec.named(companion) != nil
    }

    private var footerText: String {
        guard creatureChosen else {
            return "M1K3's face in chat. Pick a 3D companion to bring it to life on device."
        }
        #if os(visionOS)
            return "Your companion appears in chat with its own textures."
        #else
            return "Phosphor is a glowing rim that shifts with M1K3's mood; Cel toon-bands the creature's own texture."
        #endif
    }

    var body: some View {
        Section {
            preview
            faceGrid
            // The skin (shading) picker is macOS/iOS only — CustomMaterial surface
            // shaders aren't available on visionOS, so a creature there shows its
            // baked textures and the picker would be a no-op.
            #if !os(visionOS)
                if creatureChosen {
                    Picker("Skin", selection: $shadingRaw) {
                        ForEach(CompanionShadingStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                }
            #endif
        } header: {
            Text("Companion")
        } footer: {
            Text(footerText)
        }
    }

    /// The live face — the real AvatarSurface, so every choice below updates it at
    /// once. "Say hi" pokes a beat so the face demonstrably lives.
    private var preview: some View {
        AvatarSurface(controller: core.avatar)
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 14))
            .overlay(alignment: .bottomTrailing) {
                Button("Say hi") { sayHi() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .m1k3Glass(cornerRadius: 20)
                    .padding(10)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live preview of the chosen companion face")
    }

    private var faceGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92), spacing: 10)],
            spacing: 10
        ) {
            ForEach(choices) { choice in
                faceCard(choice)
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 10, trailing: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Companion face")
    }

    private func faceCard(_ choice: FaceChoice) -> some View {
        let isSelected = companion == choice.id
        return Button {
            companion = choice.id
        } label: {
            VStack(spacing: 8) {
                mark(choice).frame(height: 26)
                Text(choice.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .m1k3Glass(cornerRadius: 12, tint: isSelected ? .accentColor.opacity(0.22) : nil)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, lineWidth: isSelected ? 2 : 0)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func mark(_ choice: FaceChoice) -> some View {
        if let glyph = choice.glyph {
            Image(systemName: glyph)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
        } else {
            // The pixel face's mark is the brand mark itself — the Silkscreen "M".
            Text("M")
                .font(.pixel(22))
                .foregroundStyle(.tint)
        }
    }

    /// A quick greeting beat on the shared controller, then back to idle — unless a
    /// real activity took over meanwhile (don't stomp a live thinking/speaking state).
    private func sayHi() {
        core.avatar.setEmotion(.excited)
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if core.avatar.state.activity == .idle {
                core.avatar.resetToIdle()
            }
        }
    }
}
