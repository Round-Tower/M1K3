//
//  OnboardingScreen.swift
//  M1K3iOS / M1K3visionOS
//
//  First run: meet M1K3, pick a brain, pick a face. The chosen face fills the
//  whole screen behind the cards through a CRT pass (the Mac's wake-screen
//  feel), so the first thing you meet is the character, not a form. The brain
//  list is the device-honest MobileBrainMenu — Mini only where Apple
//  Intelligence runs, Lil only above its memory floor, and Brain at Home always,
//  which on an old iPad is the ONLY row (Kev's 8th-gen iPad, QA pass 2026-09-05).
//  Picking Home opens the pairing ceremony right here; a paired Mac completes
//  the step. No GB download bar on the entry screen: Mini is instant, and Lil's
//  download is honest and deferred to first use.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.75. Prior: Unknown.
//
//  Review: Kev + claude-fable-5.1, 2026-09-03 — cognitive-load cut: the two-line tagline became the one instruction the
//  screen needs; the lock line below already carries the privacy promise.
//  Review: Kev + claude-fable-5.1, 2026-09-05 — the full sweep: full-bleed avatar + CRT behind the cards; brain rows
//  from MobileBrainMenu (Home included, locked rows gone); a second step picks the face (Phosphor Fox is the registered
//  default); Home pairs in-place. Confidence now 0.8 (layout verify-by-launch on iPad 8th gen + iPhone 17 Pro).
//

import M1K3Avatar
import M1K3Inference
import SwiftUI

struct OnboardingScreen: View {
    @Environment(AppCore.self) private var core
    @AppStorage(CompanionDefaults.companionKey) private var companion = ""
    let onDone: () -> Void

    private enum Step: Equatable {
        case brain
        case face
    }

    @State private var step: Step = .brain
    @State private var pairing = false

    private var menu: MobileBrainMenu {
        core.brainMenu
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 20) {
                Spacer(minLength: 12)
                Text("M1K3")
                    .font(.pixel(34))
                    .kerning(3)
                    .foregroundStyle(.white)
                Text(step == .brain ? "Pick a brain." : "Pick a face.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                switch step {
                case .brain: brainStep
                case .face: faceStep
                }

                // Honest on a Home-only device: the brain is your Mac, not this iPad.
                Label(
                    menu.localFallback == nil && !menu.options.contains(.tier(.mini))
                        ? "Runs on your own Mac, over your own Wi‑Fi"
                        : "Everything runs on your device",
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

                Spacer()
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: step)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $pairing, onDismiss: pairingDismissed) {
            NavigationStack { BrainPairingScreen() }
        }
        // The ceremony's Task outlives a swiped-away sheet: when the Mac's
        // approval lands late, the pairing still counts as the pick (review catch).
        .onChange(of: core.homeBrain?.identity) { _, identity in
            guard identity != nil, step == .brain, !pairing else { return }
            core.selectHomeBrain()
            step = .face
        }
        .onAppear {
            // A lively "hello" beat that settles into a warm smile — the face
            // greets you rather than sitting neutral behind the copy.
            core.avatar.setEmotion(.excited)
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                core.avatar.setEmotion(.happy)
            }
        }
    }

    // MARK: - Backdrop

    /// The chosen face, full-bleed, through the CRT pass. The pixel face carries
    /// its own scanlines (AvatarView), so the overlay is added only for a creature;
    /// a gradient scrim keeps the cards legible over a bright body.
    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.11), .black],
                startPoint: .top, endPoint: .bottom
            )
            if !CompanionDefaults.hidesAvatar(companion) {
                AvatarSurface(controller: core.avatar)
                    .scaleEffect(1.15)
                    .opacity(0.85)
                // Same test AvatarSurface uses to render a creature — a spec with no
                // installed assets falls back to the pixel face, which has its own CRT.
                if let spec = CompanionSpec.named(companion), CompanionAssets.isInstalled(spec) {
                    CRTOverlay()
                }
            }
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.15), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.45),
                    .init(color: .black.opacity(0.8), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Step 1: brain

    private var brainStep: some View {
        VStack(spacing: 12) {
            ForEach(menu.options) { option in
                switch option {
                case let .tier(tier): brainCard(tier)
                case .brainAtHome: homeCard
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func brainCard(_ tier: BrainTier) -> some View {
        Button {
            core.selectBrain(tier)
            step = .face
        } label: {
            cardBody(
                glyph: tier.glyph,
                title: tier.displayName,
                recommended: menu.recommended == .tier(tier),
                detail: tier.detail,
                footnote: tier.approxDownloadMB.map { "~\($0) MB download on first use" } ?? "No download — instant"
            )
        }
        .buttonStyle(.plain)
    }

    private var homeCard: some View {
        Button {
            if core.homeBrain != nil {
                core.selectHomeBrain()
                step = .face
            } else {
                pairing = true
            }
        } label: {
            cardBody(
                glyph: "house.fill",
                title: "Home",
                recommended: menu.recommended == .brainAtHome,
                detail: core.homeBrain.map { "\($0.name)’s brain, over your Wi‑Fi." }
                    ?? "Your Mac’s brain, over your own Wi‑Fi. Scan a code to pair.",
                footnote: core.homeBrain == nil ? "Needs M1K3 on your Mac" : "Paired"
            )
        }
        .buttonStyle(.plain)
    }

    private func cardBody(
        glyph: String, title: String, recommended: Bool, detail: String, footnote: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: glyph)
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    if recommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.tint, in: .capsule)
                            .foregroundStyle(.white)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding(16)
        .m1k3Glass(cornerRadius: 18)
    }

    /// The pairing sheet closed: a paired Mac means Home was the pick.
    private func pairingDismissed() {
        guard core.homeBrain != nil else { return }
        core.selectHomeBrain()
        step = .face
    }

    // MARK: - Step 2: face

    private struct FaceChoice: Identifiable {
        let id: String
        let name: String
    }

    private var faces: [FaceChoice] {
        CompanionSpec.all.filter(CompanionAssets.isInstalled).map { FaceChoice(id: $0.id, name: $0.displayName) }
            + [FaceChoice(id: "", name: "Pixel face"), FaceChoice(id: CompanionDefaults.noneID, name: "None")]
    }

    private var faceStep: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                ForEach(faces) { face in
                    let selected = companion == face.id
                    Button {
                        companion = face.id
                        core.avatar.setEmotion(.excited)
                    } label: {
                        Text(face.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                            .m1k3Glass(cornerRadius: 12, tint: selected ? .accentColor.opacity(0.22) : nil)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(.tint, lineWidth: selected ? 2 : 0)
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            Button {
                onDone()
            } label: {
                Text("Say hello")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .m1k3Glass(cornerRadius: 16, tint: .accentColor.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }
}
