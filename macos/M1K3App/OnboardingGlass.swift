//
//  OnboardingGlass.swift
//  M1K3App
//
//  The one Liquid Glass card the onboarding sheet wears: the hello card (name + the two doors)
//  and the setup deck (title, card, arrows, caption) share it, so both read as the same room.
//  Kev, TestFlight 499: "The UI needs to be centered, and liquid glass."
//
//  Mac-only on purpose (iOS has no HelloView). The wait path's progress footer stays OUTSIDE this
//  surface: a glassEffect that re-renders on download-progress ticks is the known NSGenericException
//  layout crash (see the banner comment in ContentView.swift).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.6 (the tint is a guess at legibility over
//  the moving 3D creature; verify-by-launch, retune `tint` here and nowhere else). Prior: the hello
//  card's `.regularMaterial` panel (HelloView, 2026-09-23 readability pass).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push fold) — `nearLiveProgress`: on the first-run download
//  wait the card is material, not glass. Keeping the footer outside the glass wasn't enough: the stack is
//  centred, so a footer reflow on a tick moves the glass in the same layout pass — the crash class. Glass
//  everywhere else (re-run, no-wait first run, the Apple Intelligence wait). Confidence 0.75.
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold, round 2) — comment corrected: the rule is "no
//  ticking view inside glass, tick-stable geometry", not "glass never shares a layout pass with ticks".
//  Confidence 0.8.
//

import SwiftUI

extension View {
    /// Padding, a stable 560 pt maximum width, and the shared glass surface. `nearLiveProgress`
    /// is true while a download bar ticks beside the card (the first-run download wait): then the
    /// surface is `.regularMaterial`, the resolution the ContentView banner crash settled on.
    /// The rule: no ticking view inside glass, and no tick may move or resize a glass surface
    /// (body re-evaluation alone is fine). Every other phase is Liquid Glass.
    func onboardingCard(nearLiveProgress: Bool = false) -> some View {
        modifier(OnboardingCardStyle(nearLiveProgress: nearLiveProgress))
    }
}

private struct OnboardingCardStyle: ViewModifier {
    let nearLiveProgress: Bool

    /// A light dark wash so body text holds up over the fox's moving lattice; clear glass alone
    /// let the wireframe run through the copy (the 2026-09-23 readability note).
    private static let tint = Color.black.opacity(0.18)
    private static let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    func body(content: Content) -> some View {
        let padded = content
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: 560)
        if nearLiveProgress {
            padded.background(.regularMaterial, in: Self.shape)
        } else {
            padded.glassEffect(.regular.tint(Self.tint), in: .rect(cornerRadius: 26))
        }
    }
}
