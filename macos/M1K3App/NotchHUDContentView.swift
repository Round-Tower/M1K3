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
//  strings. And the narrator caption needed 10pt to fit; `.pixel` floors at
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
//  Review: Kev + claude-fable-5.1, 2026-09-08 — the caption names the NARRATOR (M1K3 / the visiting MCP client)
//  instead of brain · voice tier — the plumbing nobody asked about. Confidence now 0.8 (verify-by-launch).
//
//  Review: Kev + claude-fable-5.1, 2026-09-11 — the marquee shows the SENTENCE being spoken
//  (`NarrationLine`, from the karaoke's word range), one line, whitespace collapsed: a visiting
//  agent's multi-paragraph `speak` had rendered as stacked full-width lines clipped both sides
//  (`fixedSize` honours embedded newlines). Confidence now 0.8 (verify-by-launch: a long `speak`).
//  Review: Kev + claude-fable-5.1, 2026-09-11 (review 4 fold) — the marquee identity is
//  (utterance sequence, sentence start), not the start alone: consecutive one-sentence
//  utterances all start at 0 and relied on an intervening `clear()` render to restart.
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the avatar slot mounts only while the HUD window is on
//  screen (`\.windowVisible`, tracked by NotchHUDWindow). The window is built on first show and lives
//  ordered-out forever after; its 72 px Fox kept RealityKit rendering at display rate — measured as the
//  single biggest idle cost in the app (~33% CPU, fan on). Confidence now 0.8 (verify-by-launch).
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the marquee FOLLOWS the voice (hold at the start, scroll
//  only to keep the spoken word inside `MarqueeMetrics.readingZone`, never backwards, edges faded where text
//  continues) instead of bouncing at 45 pt/s — Kev's screenshot showed mid-word hard clips on both sides.
//  The creature drops its tile and takes `CompanionAvatarView`'s `.fit` framing (camera placed for the slot's
//  aspect) so a 72px slot shows the whole fox, not a boxed distant thumbnail — a closer fixed shot clipped the
//  head. Confidence 0.75 (verify-by-launch: a long `speak`).
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the panel is the WINDOW's fixed size (it sized to
//  each sentence and pulsed) and hugs the notch: flat top, rounded bottom corners (Kev's pick). A
//  material, not `glassEffect(in:)` — on macOS 27.0 the glass ignored the uneven shape and drew
//  short of the frame (window-rect capture on the first release build). Confidence 0.8
//  (verify-by-launch on the second).
//  Review: Kev + claude-opus-5, 2026-09-14 — on a notched screen the panel grows out of the notch
//  (`NotchHUDGeometry.contentTopInset`): black fill, no hairline, content below the notch strip.
//  Docked panels keep the material. Confidence 0.8 (verify-by-launch).
//  Review: Kev + claude-opus-5, 2026-09-14 — grown from the notch it is a HUD (Kev: "avatar centred?
//  and bigger?"): a 110 pt creature centred, the spoken line centred under it (scrolls when it runs
//  past), the caption below. The docked row is unchanged. Confidence 0.75 (verify-by-launch).
//  Review: Kev + claude-opus-5, 2026-09-14 — "clipping on the avatar… grow in? CRT it? Liquid glass": fit
//  headroom 1.7 (the walk cycle overran 1.25), the panel scales in from the notch's rectangle, Liquid Glass
//  under a black band that melts out of the notch, and the house CRTOverlay over it. Confidence 0.7.
//  Review: Kev + claude-opus-5, 2026-09-14 — "no background to the avatar… reduce the black fade… a close /
//  stop button": smoked glass (translucent fill + sheen + rim), because backdrop blurs can't sample through
//  the RealityView and drew a box on bright desktops; the band fades in 12 pt; a hover-only stop button calls
//  `stopSpeaking()`. Confidence 0.75 (verify-by-launch).

import M1K3Avatar
import M1K3Voice
import SwiftUI

/// The marquee's SwiftUI identity: one per (utterance, sentence position).
private struct MarqueeKey: Hashable {
    let utterance: Int
    let start: Int
}

struct NotchHUDContentView: View {
    let env: AppEnvironment
    let geometry: NotchHUDGeometry
    @AppStorage(AppEnvironment.voiceCompanionKey) private var companion = ""
    /// Ordered-out HUD → no creature at all (the fallback path below bypasses
    /// AvatarSurface's own gate, so it is gated here).
    @Environment(\.windowVisible) private var windowVisible

    /// ONE line: the sentence being spoken, not the whole utterance. A
    /// visiting agent's multi-paragraph `speak` is a single utterance with
    /// embedded newlines; rendered whole it stacked as full-width lines the
    /// panel clipped on both sides (Kev's screenshot, 2026-09-11). The chat's
    /// own auto-speak speaks a sentence per utterance, so it never showed.
    private var narration: NarrationLine.Line? {
        guard let text = env.speechHighlight.utteranceText, !text.isEmpty else { return nil }
        let line = NarrationLine.currentLine(in: text, wordRange: env.speechHighlight.currentWordRange)
        return line.text.isEmpty ? nil : line
    }

    var body: some View {
        panel
            // Under a notch the panel grows in from the notch's own rectangle and
            // folds back into it (the controller drives `expanded`).
            .scaleEffect(x: foldedScale.width, y: foldedScale.height, anchor: .top)
            .frame(width: NotchHUDLayout.size.width, height: totalHeight, alignment: .top)
    }

    private var totalHeight: CGFloat {
        geometry.contentHeight + geometry.contentTopInset
    }

    /// 1×1 when expanded; the notch's size relative to the panel when folded.
    private var foldedScale: CGSize {
        guard geometry.growsFromNotch, !geometry.expanded else { return CGSize(width: 1, height: 1) }
        let width = geometry.notchWidth > 0 ? geometry.notchWidth : 200
        return CGSize(
            width: min(1, width / NotchHUDLayout.size.width),
            height: min(1, geometry.contentTopInset / totalHeight)
        )
    }

    private var panel: some View {
        content
            .opacity(geometry.growsFromNotch && !geometry.expanded ? 0 : 1)
            // FIXED size — the panel fills the window every frame. Sized to its
            // content it grew and shrank with each sentence (Kev: "expanding when
            // talking", 2026-09-12); the window is fixed, so the panel is too.
            .frame(width: NotchHUDLayout.size.width, height: geometry.contentHeight)
            // On a notched screen the content sits below the notch strip.
            .padding(.top, geometry.contentTopInset)
            .frame(width: NotchHUDLayout.size.width, height: totalHeight)
            .background { panelBackground }
            .overlay {
                // No hairline on the notched panel: a border would draw the seam
                // between the notch and the panel that the black band hides.
                if !geometry.growsFromNotch {
                    NotchHUDLayout.shape.strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
            }
    }

    /// Grown from the notch it is a HUD: a big creature centred under the
    /// notch, the spoken line and who is speaking below it (Kev, 2026-09-14).
    /// Docked under a plain menu bar it stays the compact row.
    @ViewBuilder private var content: some View {
        if geometry.growsFromNotch {
            VStack(spacing: 6) {
                avatarSlot
                    .frame(width: NotchHUDLayout.hudAvatarSlot.width, height: NotchHUDLayout.hudAvatarSlot.height)
                narrationText(width: NotchHUDLayout.hudTextWidth, centred: true)
                captionText
            }
            .padding(.top, 4)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if geometry.hovered { stopButton.transition(.opacity) }
            }
        } else {
            HStack(spacing: NotchHUDLayout.interItemSpacing) {
                // No tile behind the creature: on the glass it read as a boxed
                // thumbnail (Kev's screenshot, 2026-09-12); `.fit` framing places
                // the camera so the whole creature fills this square slot.
                avatarSlot
                    .frame(width: NotchHUDLayout.avatarSize, height: NotchHUDLayout.avatarSize)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    narrationText(width: NotchHUDLayout.textAreaWidth, centred: false)
                    captionText
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NotchHUDLayout.horizontalPadding)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder private func narrationText(width: CGFloat, centred: Bool) -> some View {
        if let narration {
            NotchHUDMarquee(
                text: narration.text,
                width: width,
                wordEnd: wordEnd(in: narration),
                lineLength: narration.length,
                centred: centred
            )
            // Fresh @State per new sentence — restart the scroll, not
            // continue it. Keyed on the UTTERANCE and the sentence's
            // position in it: two identical sentences in a row are
            // still two sentences, and two one-sentence utterances
            // (both at offset 0) are still two utterances — whether
            // or not the `clear()` between them ever rendered.
            .id(MarqueeKey(utterance: env.speechHighlight.utteranceSequence, start: narration.start))
        } else {
            Text("M1K3 IS TALKING")
                .font(.pixel(18))
                .kerning(1)
                .foregroundStyle(.white)
        }
    }

    /// Stops the speech (and the visitor queue behind it), same as the MCP
    /// `stop_speaking` tool; the HUD then folds away on its own. Shown while
    /// the pointer is over the panel.
    private var stopButton: some View {
        Button {
            Task { await env.stopSpeaking() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .padding(.trailing, 14)
        .help("Stop talking")
        .accessibilityLabel("Stop talking")
    }

    /// WHO is talking, not which brain/voice renders it (hit list
    /// 2026-09-08, item 2): "M1K3", or "CLAUDE CODE · VIA M1K3".
    private var captionText: some View {
        Text(NarrationCaption.text(for: env.speechHighlight.narrator))
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.55))
    }

    /// Under a notch: smoked glass. A translucent dark fill with a glass
    /// highlight, not a backdrop blur: Liquid Glass (and any material) cannot
    /// sample through the creature's Metal layer, so the region behind the
    /// RealityView rendered as a visible box on a bright desktop (Kev's
    /// screenshot, 2026-09-14; the same box was hit with the material on
    /// 2026-09-12). A short black band joins it to the notch, and the house
    /// CRT sits over it. Docked panels keep the material.
    @ViewBuilder private var panelBackground: some View {
        if geometry.growsFromNotch {
            ZStack {
                Rectangle().fill(.black.opacity(0.86))
                // Glass sheen: a faint light from the top that fades out.
                LinearGradient(
                    colors: [.white.opacity(0.07), .clear],
                    startPoint: .top, endPoint: .center
                )
                LinearGradient(stops: notchBandStops, startPoint: .top, endPoint: .bottom)
                CRTOverlay()
                    .opacity(0.8)
            }
            .clipShape(NotchHUDLayout.shape)
            // The glass edge: a thin highlight on the rounded bottom rim.
            .overlay {
                NotchHUDLayout.shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.22)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
        } else {
            NotchHUDLayout.shape.fill(.regularMaterial)
        }
    }

    /// Solid black through the notch, blending into the glass ~12 pt below it.
    private var notchBandStops: [Gradient.Stop] {
        let notch = geometry.contentTopInset / max(1, totalHeight)
        let fade = min(1, notch + 12 / max(1, totalHeight))
        return [
            .init(color: .black, location: 0),
            .init(color: .black, location: notch),
            .init(color: .clear, location: fade),
        ]
    }

    /// Where the word being spoken ENDS, in UTF-16 units from the line's
    /// start — the follow marquee keeps that point inside its reading zone.
    /// nil word (the utterance just began) reads as 0: hold at the start.
    private func wordEnd(in line: NarrationLine.Line) -> Int {
        guard let word = env.speechHighlight.currentWordRange else { return 0 }
        return word.upperBound - line.start
    }

    /// Wider than `.fit`'s 1.25: that frames the creature's POSED extents, and
    /// the walk cycle's raised head and stride ran past them and clipped flat
    /// in the bigger HUD slot (Kev's screenshot, 2026-09-14). 1.7 fixed that but
    /// shrank him; a wide slot (the fox is long, not tall) at 1.8 does both (1.4 clipped his head).
    private static let hudFraming = CompanionFraming.fit(headroom: 1.8)

    /// A real installed creature pick renders as-is; anything else falls back
    /// to the house default creature rather than the constellation or the
    /// pixel face, both live-confirmed illegible at 72px — see header for the
    /// full story. Both go through `CompanionAvatarView` directly (not
    /// `AvatarSurface`) so the HUD can ask for the aspect-aware `.fit` framing.
    /// The docked 72 pt slot keeps the `.fit` (1.25) it was live-tuned with;
    /// only the notch HUD's wide slot needs the extra headroom (#326 review).
    private var slotFraming: CompanionFraming {
        geometry.growsFromNotch ? Self.hudFraming : .fit
    }

    @ViewBuilder
    private var avatarSlot: some View {
        if !windowVisible {
            // Ordered-out HUD → no RealityView at all (2026-09-12 thermal audit).
            EmptyView()
        } else if let spec = CompanionSpec.named(companion), CompanionAssets.isInstalled(spec) {
            CompanionAvatarView(controller: env.avatar, companion: spec, framing: slotFraming, tile: !geometry.growsFromNotch)
                .id(spec.id)
        } else {
            CompanionAvatarView(controller: env.avatar, companion: houseFallbackCompanion, framing: slotFraming, tile: !geometry.growsFromNotch)
                .id(houseFallbackCompanion.id)
        }
    }

    private var houseFallbackCompanion: CompanionSpec {
        CompanionAssets.isInstalled(.phosphorFox) ? .phosphorFox : .fox
    }
}

/// A marquee that FOLLOWS the voice: the line holds at its start and scrolls
/// only as far as it takes to keep the word being spoken inside a reading
/// zone, never backwards, with soft edges where text continues past the
/// viewport. The offset math lives in `MarqueeMetrics.followOffset` (M1K3Voice,
/// unit-pinned) — this view is the SwiftUI wiring around it. Replaces the
/// fixed-rate bounce, which clipped mid-word on both edges and could be a
/// sentence ahead of or behind the voice (Kev's screenshot, 2026-09-12).
private struct NotchHUDMarquee: View {
    let text: String
    let width: CGFloat
    let wordEnd: Int
    let lineLength: Int
    /// Centre a line that fits (the HUD layout); a line that runs past the
    /// viewport scrolls from the leading edge either way.
    var centred = false

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0

    private static let fade: CGFloat = 14

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1) // a marquee scrolls ONE line; `fixedSize` alone honours embedded newlines
            .fixedSize()
            .background(GeometryReader { geo in
                Color.clear.onAppear { textWidth = geo.size.width }
            })
            .offset(x: offset)
            .frame(width: width, alignment: centred && textWidth <= width ? .center : .leading)
            .clipped()
            .mask(edgeMask)
            .onChange(of: wordEnd, initial: true) { _, _ in follow() }
            .onChange(of: textWidth) { _, _ in follow() }
    }

    /// Fade only the edge text actually runs past: the leading edge once the
    /// line has scrolled, the trailing edge while text is still to come. A
    /// hard cut mid-glyph is what read as "clipping" in the screenshot.
    private var edgeMask: some View {
        let leading: CGFloat = offset < 0 ? Self.fade : 0
        let trailing: CGFloat = textWidth + offset > width ? Self.fade : 0
        return HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: leading)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: trailing)
        }
    }

    private func follow() {
        guard textWidth > 0 else { return }
        let target = CGFloat(MarqueeMetrics.followOffset(
            wordEnd: wordEnd, lineLength: lineLength, textWidth: Double(textWidth), viewportWidth: Double(width)
        ))
        // Monotone: a caption never scrolls back toward words already heard.
        guard target < offset else { return }
        withAnimation(.easeOut(duration: 0.35)) { offset = target }
    }
}
