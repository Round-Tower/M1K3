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
//

import SwiftUI

extension View {
    /// Padding, a stable 560 pt maximum width, and the shared glass surface.
    func onboardingCard() -> some View {
        modifier(OnboardingCardStyle())
    }
}

private struct OnboardingCardStyle: ViewModifier {
    /// A light dark wash so body text holds up over the fox's moving lattice; clear glass alone
    /// let the wireframe run through the copy (the 2026-09-23 readability note).
    private static let tint = Color.black.opacity(0.18)

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: 560)
            .glassEffect(.regular.tint(Self.tint), in: .rect(cornerRadius: 26))
    }
}
