//
//  AvatarSurface.swift
//  M1K3App
//
//  The avatar, resolved from the user's companion choice — SHARED by every roomy
//  surface (the main-window panel and the voice-mode hero) so the chosen face
//  carries throughout, not just in voice mode. One place decides what the avatar
//  is; both callers render it.
//
//  The tiny menu-bar glyph + popover header are deliberately NOT routed through
//  here: a live 3D constellation can't render at 16–20px, so those stay M1K3's
//  pixel-M brand mark (the app's identity, distinct from the companion skin).
//  (The popover's full-bleed BACKDROP is different — since 2026-07-14 it routes
//  through here via AvatarChatBackground at hero size, same as the main chat;
//  the not-at-glyph-size rule above is about tiny renders, not the popover.)
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.75 (DRY selection +
//  compiles; the look in each surface is verify-by-run). Prior: VoiceModeView.avatar.
//  Review: claude-fable-5, 2026-07-18 — `paused` pass-through added so
//  AvatarChatBackground can finally honor ChatBackdropTreatment.animatesMotion
//  (recede/still/Reduce Motion freeze the pixel face; constellation + companion
//  surfaces don't take a pause yet — logged follow-up, they receive it as a
//  no-op param when they do).
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the thermal audit's seam: the
//  surface resolves an `AvatarPresence` (M1K3Avatar, test-pinned) from the
//  window's occlusion-derived visibility (`\.windowVisible`), the caller's
//  `paused`, and Low Power Mode. A window nobody can see mounts NO RealityView
//  (the only thing that stops RealityKit's render loop — one hidden Fox cost
//  ~33% CPU at idle); a visible-but-still surface is paused; and the pause
//  finally reaches the creature + constellation too (the 07-18 follow-up
//  closed). Confidence now 0.85 (mount/pause verify-by-launch).
//  Review: Kev + claude-fable-5.1, 2026-09-12 — `framing` pass-through so the voice-mode
//  hero can take `.fit` (whole creature, head included). Confidence now 0.85.

import M1K3Avatar
import SwiftUI

struct AvatarSurface: View {
    let env: AppEnvironment
    /// Freeze idle motion (all three surfaces since 2026-09-12 — see header Review).
    var paused = false
    /// Camera framing for a creature pick (ignored by the pixel face and the
    /// constellation). `.window` is the main panel's fixed shot; the voice-mode
    /// hero asks for `.fit` so the whole creature sits in the window at any
    /// aspect (the fixed shot clipped the fox's head in every voice screenshot).
    var framing: CompanionFraming = .window
    @AppStorage(AppEnvironment.voiceCompanionKey) private var companion = ""
    /// Published by `.trackWindowVisibility()` at the window root; `true` where
    /// no root tracks it (today's behaviour for untracked windows).
    @Environment(\.windowVisible) private var windowVisible

    private var presence: AvatarPresence {
        AvatarPresence.resolve(
            windowVisible: windowVisible,
            animatesMotion: !paused,
            // Not observable; read at render like ChatBackdropTreatment does.
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    var body: some View {
        // The constellation canvas stays mounted through an unmount (it owns
        // the polled model — dropping it would relayout + regrow on every
        // reveal); it drops its own RealityView on `.unmounted`. The creature
        // and the pixel face rebuild cheaply, so they simply go away.
        if companion == AppEnvironment.voiceCompanionConstellation {
            MemoryConstellationCanvas(env: env, presence: presence)
        } else if !presence.isMounted {
            // No surface at all: nothing to see, nothing to render.
            EmptyView()
        } else if let spec = CompanionSpec.named(companion), CompanionAssets.isInstalled(spec) {
            // .id(spec.id): a creature→creature switch must REBUILD the RealityView
            // (fresh identity → fresh CompanionScene + make closure). Without it,
            // SwiftUI updates the view in place and the previous creature's built
            // scene survives — the picker appears to do nothing. Pixel↔creature↔
            // constellation switches change the view TYPE, so only same-type
            // swaps hit this; it fires only on an actual different companion
            // (the onboarding per-step-rebuild trap is the opposite failure).
            CompanionAvatarView(controller: env.avatar, companion: spec, framing: framing, paused: presence.isPaused)
                .id(spec.id)
        } else {
            AvatarView(controller: env.avatar, paused: presence.isPaused)
        }
    }
}
