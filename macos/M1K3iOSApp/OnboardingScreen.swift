//
//  OnboardingScreen.swift
//  M1K3iOS / M1K3visionOS
//
//  One-screen first run: meet M1K3 (the pixel face), pick a brain. The
//  recommendation is computed from this device's RAM via the mobile ladder
//  (BrainTier.recommended(platform:.mobile)) — iPhones land on Mini, ≥16 GB
//  iPad Pro / Vision Pro can pick Lil. No GB download bar on the entry screen:
//  Mini is instant, and Lil's download is honest and deferred to first use.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.75. Prior: Unknown.
//
//  Review: Kev + claude-fable-5.1, 2026-09-03 — cognitive-load cut: the two-line tagline became the one instruction the
//  screen needs; the lock line below already carries the privacy promise.
//

import M1K3Avatar
import M1K3Inference
import SwiftUI

struct OnboardingScreen: View {
    @Environment(AppCore.self) private var core
    let onDone: () -> Void

    private var recommended: BrainTier {
        BrainTier.recommended(forPhysicalMemoryGB: Self.physicalMemoryGB, platform: .mobile)
    }

    /// Mobile-safe tiers (Big exceeds the mobile budget).
    private var brains: [BrainTier] {
        [.mini, .lil]
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            AvatarSurface(controller: core.avatar)
                .frame(width: 160, height: 160)
            Text("M1K3")
                .font(.pixel(34))
                .kerning(3)
                .foregroundStyle(.white)
            Text("Pick a brain.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                ForEach(brains) { tier in
                    brainCard(tier)
                }
            }
            .padding(.horizontal, 20)

            Label("Everything runs on your device", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Spacer()
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.11), .black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
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

    private func brainCard(_ tier: BrainTier) -> some View {
        Button {
            core.selectBrain(tier)
            onDone()
        } label: {
            HStack(spacing: 14) {
                // `glyph` is an SF Symbol NAME (e.g. "hare.fill"), not an emoji.
                Image(systemName: tier.glyph)
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tier.displayName).font(.headline).foregroundStyle(.white)
                        if tier == recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.tint, in: .capsule)
                                .foregroundStyle(.white)
                        }
                    }
                    Text(tier.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    if let mb = tier.approxDownloadMB {
                        Text("~\(mb) MB download on first use")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("No download — instant")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(16)
            .m1k3Glass(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }
}
