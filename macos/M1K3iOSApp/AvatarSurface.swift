//
//  AvatarSurface.swift
//  M1K3iOS / M1K3visionOS
//
//  Resolves the user's avatar choice to a concrete face — the procedural pixel
//  face or an opt-in 3D creature — so EVERY roomy avatar surface on the phone /
//  Vision Pro (the chat hero, the reactive backdrop, onboarding, the Settings
//  live preview) renders the SAME chosen companion. The iOS sibling of the Mac's
//  AvatarSurface: one place decides what the avatar is, every caller renders it.
//
//  The constellation renders on the iPad (2026-09-08) via the shell's own
//  MemoryConstellationCanvas; on a phone its sentinel still falls through to
//  the pixel face rather than showing an illegible scatter.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-28, Confidence 0.8 (DRY selection +
//  compiles; the on-device creature render is verify-by-launch, same posture as
//  the rest of the shell — the simulator has no Metal). Prior: none (new file,
//  patterned on the Mac's AvatarSurface.swift).
//  Review: Kev + claude-fable-5.1, 2026-09-08 — the memory constellation renders here on the iPad (hit list
//  item 6); phones keep the pixel-face fallback. Confidence now 0.75 (device-owed).
//

import M1K3Avatar
import SwiftUI

struct AvatarSurface: View {
    let controller: AvatarController
    /// Freeze idle motion — honored by the pixel face; the creature surface ignores
    /// it today (same as the Mac, where the companion `paused` pass-through is a
    /// logged follow-up).
    var paused = false
    /// Optional: mirrors a creature's mesh load (true while loading). The pixel
    /// face is instant and never sets it.
    var loading: Binding<Bool>? = nil

    @AppStorage(CompanionDefaults.companionKey) private var companion = ""

    /// The constellation is a full-canvas field — legible on the iPad, a grey
    /// scatter on a phone (the Mac's notch-HUD lesson at 72px). Offered on the
    /// pad only; elsewhere the sentinel keeps falling through to the pixel face.
    static var offersConstellation: Bool {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .pad
        #else
            false
        #endif
    }

    var body: some View {
        if companion == CompanionDefaults.constellationID, Self.offersConstellation {
            MemoryConstellationCanvas()
        } else if let spec = CompanionSpec.named(companion), CompanionAssets.isInstalled(spec) {
            // Deliberately NO .id(spec.id): on iOS, recreating the RealityView on a
            // switch left the new one BLACK (the iOS RealityView "swap → black"
            // lifecycle trap). CompanionAvatarView now reloads the creature IN PLACE
            // in its update closure (a persistent root, one RealityView), so we keep
            // the same view identity and let it swap the mesh itself. (The Mac's
            // AvatarSurface keeps .id — recreation renders fine there.)
            CompanionAvatarView(controller: controller, companion: spec, loading: loading)
        } else {
            AvatarView(controller: controller, paused: paused)
        }
    }
}
