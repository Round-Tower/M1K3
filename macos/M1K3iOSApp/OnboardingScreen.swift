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
//  Review: Kev + claude-fable-5.1, 2026-09-06 — the privacy line keys on `menu.hasLocalBrain` rather than "Mini
//  listed" — pocket is a local brain too. Confidence now 0.8.
//  Review: Kev + claude-opus-5-5, 2026-10-04 — the local-brain line says "Private by design", not "Everything runs
//  on your device" (Kev retired the absolute: web search is on by default). The Home branch is unchanged. Confidence 0.9.
//  Review: Kev + claude-opus-4-6, 2026-10-12 — removed the "Recommended" capsule badge from `cardBody()` and both
//  call sites. The tier's policy role stays in MobileBrainMenu. Confidence 0.9.
//  Review: Kev + claude-opus-5-5, 2026-10-13 — a Private Cloud Compute card after the menu's options (Kev:
//  "the on boarding Pick a brain screen also needs it"): the same one control as Settings ▸ Brain
//  (`core.pickPrivateCloud`), shown wherever the rung can exist, disabled with the reason while PCC is out.
//  Picking a phone brain or Home un-picks it. Confidence 0.8 (verify-by-device).
//
//  Review: Kev + claude-opus-5.5, 2026-10-12 — earcons (Kev's iPhone list): a selection tick on each brain and face pick,
//  the done chord on "Say hello". Ambient session, so they honour the silent switch. Verify-on-device.
//  Review: Kev + claude-fable-5.2, 2026-11-13 — Xcode's accessibility audit found 23 issues here (contrast 9, clipped 9,
//  not scaling 5). The supporting copy is plain white at a fixed opacity instead of the vibrancy styles, the column
//  scrolls when it outgrows the screen (it could only compress), and the wordmark scales with text size. Measured by
//  re-running the audit on a Simulator; the look is verify-on-device. Confidence 0.65.

import M1K3Avatar
import M1K3Inference
import M1K3LanguageModel
import SwiftUI

struct OnboardingScreen: View {
    @Environment(AppCore.self) private var core
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(CompanionDefaults.companionKey) private var companion = CompanionDefaults.houseCompanion.id
    let onDone: () -> Void

    private enum Step: Equatable {
        case brain
        case face
    }

    @State private var step: Step = .brain
    @State private var pairing = false
    /// A creature's USDZ takes a beat to load on an A12 — say so (QA round 2).
    @State private var faceLoading = false

    private var menu: MobileBrainMenu {
        core.brainMenu
    }

    /// Supporting copy on this screen. `.secondary` / `.tertiary` are vibrancy styles: over the
    /// avatar and the glass cards they measured under the 4.5:1 contrast floor (Xcode's audit,
    /// 2026-11-13: nine failures here). Plain white at a fixed opacity holds on the dark scrim.
    private static let copy = Color.white.opacity(0.82)
    /// The cards' footnote line: quieter than `copy`, still above the floor.
    private static let quietCopy = Color.white.opacity(0.68)

    var body: some View {
        ZStack {
            backdrop
            // Scrolls when the cards outgrow the screen (larger text sizes, a small phone);
            // `minHeight` keeps the column centred exactly as before when they fit.
            GeometryReader { screen in
                ScrollView {
                    column.frame(minHeight: screen.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $pairing, onDismiss: pairingDismissed) {
            NavigationStack { BrainPairingScreen() }
        }
        // The ceremony's Task outlives a swiped-away sheet: when the Mac's
        // approval lands late, the pairing still counts as the pick (review catch).
        .onChange(of: core.homeBrain?.identity) { _, identity in
            guard identity != nil, step == .brain, !pairing else { return }
            core.pickPrivateCloud(false)
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

    /// The title, the step's instruction, its cards and the privacy line.
    private var column: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            // The wordmark scales with the reader's text size like the copy under it.
            Text("M1K3")
                .font(.custom(BundledFonts.pixelFamily, size: 34, relativeTo: .largeTitle))
                .kerning(3)
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                Text(step == .brain ? "Pick a brain." : "Pick a face.")
                if faceLoading {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                }
            }
            .font(.callout)
            .foregroundStyle(Self.copy)
            .animation(.easeInOut(duration: 0.2), value: faceLoading)

            switch step {
            case .brain: brainStep
            case .face: faceStep
            }

            // Honest on a Home-only device: the brain is your Mac, not this iPad.
            Label(
                !menu.hasLocalBrain
                    ? "Runs on your own Mac, over your own Wi‑Fi"
                    : "Private by design",
                systemImage: "lock.fill"
            )
            .font(.caption)
            .foregroundStyle(Self.copy)
            .padding(.top, 6)

            Spacer()
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: step)
    }

    // MARK: - Backdrop

    /// The chosen face, full-bleed, through the CRT pass — both faces carry their
    /// own scanlines (AvatarView and CompanionAvatarView), so nothing is added here;
    /// a gradient scrim keeps the cards legible over a bright body.
    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.11), .black],
                startPoint: .top, endPoint: .bottom
            )
            if !CompanionDefaults.hidesAvatar(companion) {
                AvatarSurface(controller: core.avatar, loading: $faceLoading)
                    .scaleEffect(1.15)
                    .opacity(0.85)
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
            if privateCloudCard != .hidden {
                privateCloudBrainCard
            }
        }
        .padding(.horizontal, 20)
        .task { await core.refreshPrivateCloudStatus() }
    }

    private var privateCloudCard: PrivateCloudRung.Control {
        PrivateCloudRung.pickerControl(core.privateCloudState(consent: nil))
    }

    /// PCC as a brain you pick, like Settings ▸ Brain. Answers come from Apple's
    /// servers; the sheet still asks before the first message leaves.
    private var privateCloudBrainCard: some View {
        Button {
            core.pickPrivateCloud(true)
            step = .face
        } label: {
            cardBody(
                glyph: "cloud.fill",
                title: PrivateCloudRung.menuTitle(privateCloudCard),
                detail: "Answers on Apple's servers. Asks before your first message leaves this device.",
                footnote: "No download — needs the internet"
            )
        }
        .buttonStyle(.plain)
        .disabled(privateCloudCard != .ready)
        .accessibilityElement(children: .combine)
    }

    private func brainCard(_ tier: BrainTier) -> some View {
        Button {
            core.soundEffects.play(.selectionTick)
            core.pickPrivateCloud(false)
            core.selectBrain(tier)
            step = .face
        } label: {
            cardBody(
                glyph: tier.glyph,
                title: tier.displayName,
                detail: tier.detail,
                footnote: tier.approxDownloadMB.map { "~\($0) MB download on first use" } ?? "No download — instant"
            )
        }
        .buttonStyle(.plain)
    }

    private var homeCard: some View {
        Button {
            core.soundEffects.play(.selectionTick)
            if core.homeBrain != nil {
                core.pickPrivateCloud(false)
                core.selectHomeBrain()
                step = .face
            } else {
                pairing = true
            }
        } label: {
            cardBody(
                glyph: "house.fill",
                title: "Home",
                detail: core.homeBrain.map { "\($0.name)’s brain, over your Wi‑Fi." }
                    ?? "Your Mac’s brain, over your own Wi‑Fi. Scan a code to pair.",
                footnote: core.homeBrain == nil ? "Needs M1K3 on your Mac" : "Paired"
            )
        }
        .buttonStyle(.plain)
    }

    private func cardBody(
        glyph: String, title: String, detail: String, footnote: String
    ) -> some View {
        // At the accessibility text sizes the glyph sits above the copy: beside it, the copy was
        // left a column a few letters wide (verified on a Simulator at the largest size).
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            Image(systemName: glyph)
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .frame(width: stacked ? nil : 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Self.copy)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(Self.quietCopy)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !stacked {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .m1k3Glass(cornerRadius: 18)
    }

    /// The pairing sheet closed: a paired Mac means Home was the pick.
    private func pairingDismissed() {
        guard core.homeBrain != nil else { return }
        core.pickPrivateCloud(false)
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
                        core.soundEffects.play(.selectionTick)
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
                core.soundEffects.play(.doneChord)
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
