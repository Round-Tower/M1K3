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
//  The constellation option is Mac-only for now (MemoryConstellationCanvas /
//  M1K3MemoryViz aren't wired into the mobile shell yet — a Phase-D follow), so
//  its sentinel falls through to the pixel face here rather than showing nothing.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-28, Confidence 0.8 (DRY selection +
//  compiles; the on-device creature render is verify-by-launch, same posture as
//  the rest of the shell — the simulator has no Metal). Prior: none (new file,
//  patterned on the Mac's AvatarSurface.swift).
//

import M1K3Avatar
import SwiftUI

struct AvatarSurface: View {
    let controller: AvatarController
    /// Freeze idle motion — honored by the pixel face; the creature surface ignores
    /// it today (same as the Mac, where the companion `paused` pass-through is a
    /// logged follow-up).
    var paused = false

    @AppStorage(CompanionDefaults.companionKey) private var companion = ""

    var body: some View {
        if let spec = CompanionSpec.named(companion), CompanionAssets.isInstalled(spec) {
            // Deliberately NO .id(spec.id): on iOS, recreating the RealityView on a
            // switch left the new one BLACK (the iOS RealityView "swap → black"
            // lifecycle trap). CompanionAvatarView now reloads the creature IN PLACE
            // in its update closure (a persistent root, one RealityView), so we keep
            // the same view identity and let it swap the mesh itself. (The Mac's
            // AvatarSurface keeps .id — recreation renders fine there.)
            CompanionAvatarView(controller: controller, companion: spec)
        } else {
            AvatarView(controller: controller, paused: paused)
        }
    }
}
