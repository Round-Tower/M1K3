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
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the marquee FOLLOWS the voice (hold at the start, scroll
//  only to keep the spoken word inside `MarqueeMetrics.readingZone`, never backwards, edges faded where text
//  continues) instead of bouncing at 45 pt/s — Kev's screenshot showed mid-word hard clips on both sides.
//  The creature drops its tile and takes `CompanionAvatarView`'s `.badge` framing (camera in close) so a
//  72px slot shows a face, not a boxed thumbnail. Confidence 0.75 (verify-by-launch: a long `speak`).

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
    @AppStorage(AppEnvironment.voiceCompanionKey) private var companion = ""

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
        HStack(spacing: NotchHUDLayout.interItemSpacing) {
            // No tile behind the creature: on the glass it read as a boxed
            // thumbnail (Kev's screenshot, 2026-09-12); the badge framing
            // brings the camera in so the face fills the slot instead.
            avatarSlot
                .frame(width: NotchHUDLayout.avatarSize, height: NotchHUDLayout.avatarSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                if let narration {
                    NotchHUDMarquee(
                        text: narration.text,
                        width: NotchHUDLayout.textAreaWidth,
                        wordEnd: wordEnd(in: narration),
                        lineLength: narration.length
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
                // WHO is talking, not which brain/voice renders it (hit list
                // 2026-09-08, item 2): "M1K3", or "CLAUDE CODE · VIA M1K3".
                Text(NarrationCaption.text(for: env.speechHighlight.narrator))
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

    /// Where the word being spoken ENDS, in UTF-16 units from the line's
    /// start — the follow marquee keeps that point inside its reading zone.
    /// nil word (the utterance just began) reads as 0: hold at the start.
    private func wordEnd(in line: NarrationLine.Line) -> Int {
        guard let word = env.speechHighlight.currentWordRange else { return 0 }
        return word.upperBound - line.start
    }

    /// A real installed creature pick renders as-is; anything else falls back
    /// to the house default creature rather than the constellation or the
    /// pixel face, both live-confirmed illegible at 72px — see header for the
    /// full story. Both go through `CompanionAvatarView` directly (not
    /// `AvatarSurface`) so the HUD can ask for the close `.badge` framing.
    @ViewBuilder
    private var avatarSlot: some View {
        if let spec = CompanionSpec.named(companion), CompanionAssets.isInstalled(spec) {
            CompanionAvatarView(controller: env.avatar, companion: spec, framing: .badge)
                .id(spec.id)
        } else {
            CompanionAvatarView(controller: env.avatar, companion: houseFallbackCompanion, framing: .badge)
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
            .frame(width: width, alignment: .leading)
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
