//
//  CompanionPickerSection.swift
//  M1K3iOS / M1K3visionOS
//
//  The avatar-customisation section of Settings — the iOS sibling of the Mac's
//  CompanionSettings. The face IS the product's identity, so choosing it shows it:
//  a LIVE preview (the real AvatarSurface, honest to every choice below it) sits
//  above a grid of glass name-cards. The cards are deliberately TEXT-ONLY — the
//  preview above is the picture; a generic pawprint beside every creature's name
//  said nothing (2026-07-29 pass, Kev's call). The skin (shading) picker appears
//  only when a 3D creature is chosen — it means nothing for the pixel face.
//
//  "None" is a first-class choice (CompanionDefaults.noneID): no hero face, no
//  live chat backdrop, no preview — just the conversation.
//
//  The creature list self-extends: a new CompanionSpec with bundled assets appears
//  here with no picker wiring (the same isInstalled filter the Mac uses). The
//  constellation is offered on the iPad (2026-09-08), where the field has room.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-28, Confidence 0.8 (composition of the
//  shared AvatarSurface + package CompanionSpec catalogue; the live creature render
//  is verify-by-launch on device — the simulator has no Metal). Prior: none (new
//  file, patterned on M1K3App/CompanionSettings.swift).
//  Review: Kev + claude-fable-5, 2026-07-29 — icons removed (text-only cards) and
//  the None option added on top of the package-pinned noneID sentinel.
//
//  Review: Kev + claude-fable-5.1, 2026-09-03 — cognitive-load cut: footers say what the choice is, not what to do
//  next.
//  Review: Kev + claude-fable-5.1, 2026-09-05 — the word "Companion" leaves the UI (header, footer, a11y labels):
//  it is the FACE. Type names keep the old word so the Mac sibling still reads as kin. Confidence now 0.85.
//  Review: Kev + claude-fable-5.1, 2026-09-08 — "Constellation" joins the grid on the iPad (hit list item 6),
//  with its own footer line. Confidence now 0.8 (device-owed).
//  Review: Kev + claude-opus-5.5, 2026-10-11 — adds the "Seasonal looks" opt-out toggle. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-11-02 — the preview holds the pixel face and a creature view from the
//  moment Settings opens and a pick only shows one: a 3D view built into this list row after the first drew black
//  (Kev's phone, fresh identity or not). None keeps the row and says so. Confidence 0.7 (verify on the phone).
//  Review: Kev + claude-opus-5.5, 2026-11-03 — "Constellation" is offered by space (regular both ways), so an
//  opened iPhone Duo lists it and a folded one doesn't. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-11-03 (pre-push review) — chosen but not shown (picked on the opened Duo,
//  then folded): the footer, Say hi and the grid's highlight follow the pixel face that stands in
//  (`constellationShown`), and the pick comes back with the space. Confidence 0.8 (verify on the Duo sim).
//

import M1K3Avatar
import SwiftUI

struct CompanionPickerSection: View {
    @Environment(AppCore.self) private var core
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(CompanionDefaults.companionKey) private var companion = CompanionDefaults.houseCompanion.id
    @AppStorage(CompanionDefaults.seasonalLooksKey) private var seasonalLooks = true
    @AppStorage(CompanionDefaults.shadingStyleKey) private var shadingRaw =
        CompanionDefaults.houseShading.rawValue
    /// The creature the preview's creature view holds while Pixel face or None shows: the
    /// last one picked, so that view is never torn down while Settings is open.
    @State private var lastCreature: String?

    /// One selectable face.
    private struct FaceChoice: Identifiable {
        let id: String
        let name: String
    }

    private var choices: [FaceChoice] {
        [FaceChoice(id: "", name: "Pixel face")]
            + CompanionSpec.all.filter(CompanionAssets.isInstalled).map {
                FaceChoice(id: $0.id, name: $0.displayName)
            }
            + (offersConstellation
                ? [FaceChoice(id: CompanionDefaults.constellationID, name: "Constellation")] : [])
            + [FaceChoice(id: CompanionDefaults.noneID, name: "None")]
    }

    private var offersConstellation: Bool {
        AvatarSurface.offersConstellation(horizontal: horizontalSizeClass, vertical: verticalSizeClass)
    }

    private var constellationChosen: Bool {
        companion == CompanionDefaults.constellationID
    }

    /// Chosen AND on screen. Chosen on the opened Duo and then folded (or an iPad window gone
    /// narrow), the stored pick stays but the pixel face stands in, as in the chat; the footer,
    /// the preview's Say hi and the grid's highlight follow what is shown, and the star field
    /// comes back when the space does (pre-push review, 2026-11-03).
    private var constellationShown: Bool {
        constellationChosen && offersConstellation
    }

    private var creatureChosen: Bool {
        CompanionSpec.named(companion) != nil
    }

    private var noneChosen: Bool {
        CompanionDefaults.hidesAvatar(companion)
    }

    private var footerText: String {
        if noneChosen {
            return "No face — just the conversation."
        }
        if constellationShown {
            return "Your memories as a star field that grows."
        }
        if constellationChosen {
            return "Constellation needs a bigger screen. The pixel face stands in for now."
        }
        guard creatureChosen else {
            return "M1K3's face in chat."
        }
        #if os(visionOS)
            return "The creature shows its own textures."
        #else
            return "Phosphor glows with M1K3's mood. Cel toon-shades the creature."
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
            Toggle("Seasonal looks", isOn: $seasonalLooks)
        } header: {
            Text("Face")
        } footer: {
            Text(footerText)
        }
    }

    /// The live face — the real AvatarSurface, so every choice below updates it at
    /// once. "Say hi" pokes a beat so the face demonstrably lives.
    private var pixelShown: Bool {
        !creatureChosen && !noneChosen && !constellationShown
    }

    /// The creature the preview's creature view shows or holds hidden.
    private var previewCreature: CompanionSpec? {
        let installed = CompanionSpec.all.filter(CompanionAssets.isInstalled)
        let held = [companion, lastCreature].compactMap { $0 }.compactMap(CompanionSpec.named)
        return held.first(where: CompanionAssets.isInstalled) ?? installed.first
    }

    /// Both 3D faces live from the moment Settings opens, and a pick only changes which one
    /// shows. A 3D view built into this list row after the first drew black, with a fresh
    /// identity or without, pixel face or creature (Kev's phone, 2026-11-02); the chat hero
    /// never hits it. Creature to creature still swaps in place inside the one creature view.
    private var faces: some View {
        ZStack {
            AvatarView(controller: core.avatar, paused: !pixelShown)
                .opacity(pixelShown ? 1 : 0)
                .allowsHitTesting(pixelShown)
                .accessibilityHidden(!pixelShown)
            if let spec = previewCreature {
                CompanionAvatarView(
                    controller: core.avatar, companion: spec, framing: .fitWhole, paused: !creatureChosen
                )
                .opacity(creatureChosen ? 1 : 0)
                .allowsHitTesting(creatureChosen)
                .accessibilityHidden(!creatureChosen)
            }
            if constellationShown {
                MemoryConstellationCanvas()
            }
            if noneChosen {
                Text("No face")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { if creatureChosen { lastCreature = companion } }
        .onChange(of: companion) { _, picked in
            if CompanionSpec.named(picked) != nil { lastCreature = picked }
        }
    }

    private var preview: some View {
        faces
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 14))
            .overlay(alignment: .bottomTrailing) {
                // The constellation and None have no face to poke — no dead button.
                if !constellationShown, !noneChosen {
                    Button("Say hi") { sayHi() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .m1k3Glass(cornerRadius: 20)
                        .padding(10)
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live preview of the chosen face")
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
        .accessibilityLabel("Face")
    }

    private func faceCard(_ choice: FaceChoice) -> some View {
        // The pixel face tile lights while it stands in for a Constellation this screen can't show.
        let isSelected = companion == choice.id || (choice.id.isEmpty && constellationChosen && !offersConstellation)
        return Button {
            companion = choice.id
        } label: {
            Text(choice.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.vertical, 14)
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
