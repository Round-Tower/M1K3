//
//  NotchHUDContentView.swift
//  M1K3App
//
//  The notch HUD's SwiftUI content: the user's actual chosen companion
//  CREATURE (via AvatarSurface, the same single source of truth the main
//  window and voice mode use) beside a scrolling marquee of what M1K3 is
//  saying right now.
//
//  Live-verified at this HUD's 72px, TWO different "honest" fallbacks both
//  read as an illegible blob, not a face: the memory constellation is a
//  sparse node-cloud designed for a full canvas (a grey scatter at 72px),
//  and the procedural LED-cube pixel face (AvatarView) — designed for a much
//  bigger frame — smears into an indistinct smudge too. Only an actual
//  creature MESH reads clean at this size (confirmed live). So a pick that
//  resolves to a real installed CompanionSpec renders as-is (honest, and
//  proven legible); anything else (constellation, pixel-face default, "no
//  avatar") falls back to the app's own house-default creature — the
//  phosphor Fox, Kev's 2026-08-06 "pretty awesome — default standard",
//  already the registered UserDefaults default in AppDelegate — rather than
//  either illegible option. Not a hardcoded ignore-the-user's-choice: a real
//  creature pick always wins.
//
//  Two more deliberate departures from the jam prototype this is promoted
//  from (scratch/jam-2026-08-31-2314/notch-hud.swift), both PixelFont.swift
//  house rules the jam didn't have in front of it: the narration text is
//  live spoken prose (dynamic content), so it wears a system font, never
//  `.pixel(_:)` — the house rule reserves that face for short, app-controlled
//  strings. And the brain/tier caption needed 10pt to fit; `.pixel` floors at
//  12pt (below that Silkscreen "turns to mush"), so it's system too. `.pixel`
//  stays for the single static "M1K3 IS TALKING" fallback header, which is
//  exactly the short, app-controlled accent the face is for.
//
//  Signed: Kev + claude-fable-5, 2026-09-01, Confidence 0.8 (the fallback
//  chain was corrected live, twice, off real screenshots — first routing the
//  constellation to the pixel face, then discovering THAT was illegible too
//  and routing to the house-default creature instead; the house-fox choice
//  is sourced from AppDelegate's own registered default + Kev's dated
//  approval, not invented. RealityKit-at-72px legibility per pick and the
//  felt entrance/exit beats remain verify-by-launch). Prior: the jam
//  prototype (Kev + claude-fable-5, same session).
//

import M1K3Avatar
import M1K3Voice
import SwiftUI

struct NotchHUDContentView: View {
    let env: AppEnvironment
    @AppStorage(AppEnvironment.voiceCompanionKey) private var companion = ""

    private var narration: String? {
        guard let text = env.speechHighlight.utteranceText, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        HStack(spacing: NotchHUDLayout.interItemSpacing) {
            avatarSlot
                .frame(width: NotchHUDLayout.avatarSize, height: NotchHUDLayout.avatarSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 3) {
                if let narration {
                    NotchHUDMarquee(text: narration, width: NotchHUDLayout.textAreaWidth)
                        .id(narration) // fresh @State per new sentence — restart the scroll, not continue it
                } else {
                    Text("M1K3 IS TALKING")
                        .font(.pixel(18))
                        .kerning(1)
                        .foregroundStyle(.white)
                }
                let brain = env.selectedBrain.displayName.uppercased()
                let tier = env.selectedVoiceTier.displayName.uppercased()
                Text("\(brain) · \(tier)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchHUDLayout.horizontalPadding)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .capsule)
    }

    /// A real installed creature pick renders as-is (via `AvatarSurface`,
    /// proven legible at this size); anything else falls back to the house
    /// default creature rather than the constellation or the pixel face,
    /// both live-confirmed illegible at 72px — see header for the full story.
    @ViewBuilder
    private var avatarSlot: some View {
        if let spec = CompanionSpec.named(companion), CompanionAssets.isInstalled(spec) {
            AvatarSurface(env: env)
        } else {
            CompanionAvatarView(controller: env.avatar, companion: houseFallbackCompanion)
                .id(houseFallbackCompanion.id)
        }
    }

    private var houseFallbackCompanion: CompanionSpec {
        CompanionAssets.isInstalled(.phosphorFox) ? .phosphorFox : .fox
    }
}

/// A scrolling marquee for narration text too wide for its viewport. Pure
/// travel/duration math lives in `MarqueeMetrics` (M1K3Voice, unit-pinned) —
/// this view is just the SwiftUI wiring around it.
private struct NotchHUDMarquee: View {
    let text: String
    let width: CGFloat
    var pointsPerSecond: Double = 45

    @State private var offset: CGFloat = 0

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .fixedSize()
            .background(GeometryReader { geo in
                Color.clear.onAppear { restart(textWidth: geo.size.width) }
            })
            .offset(x: offset)
            .frame(width: width, alignment: .leading)
            .clipped()
    }

    private func restart(textWidth: CGFloat) {
        offset = 0
        guard let plan = MarqueeMetrics.plan(
            textWidth: Double(textWidth), viewportWidth: Double(width), pointsPerSecond: pointsPerSecond
        ) else { return }
        withAnimation(.linear(duration: plan.duration).repeatForever(autoreverses: true)) {
            offset = -CGFloat(plan.travel)
        }
    }
}
