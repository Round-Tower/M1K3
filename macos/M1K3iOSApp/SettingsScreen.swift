//
//  SettingsScreen.swift
//  M1K3iOS / M1K3visionOS
//
//  Brain choice, grounding options, and the honest about box. The brain picker
//  offers only the mobile-safe tiers (Mini = Apple Intelligence, Lil = MLX
//  Qwen3-4B); Big (gemma-4-12B, ~7.4 GB at inference) exceeds any current mobile
//  budget and is deliberately not offered (BrainTier.recommended(platform:.mobile)).
//
//  Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.8. Prior: Unknown.
//  Review: claude-fable-5, 2026-07-18 — added the Reading section (the shared
//  ReadingMode picker + live ReadingText preview), part of the Mac-feel pass.
//
//  Review: Kev + claude-fable-5.1, 2026-09-03 — cognitive-load pass (the Mac's #171 footer reduction, applied here):
//  every footer down to the fact + the guarantee; the one-row Knowledge section folded into the Documents row; the
//  reading sample stopped instructing.
//
//  Review: Kev + claude-fable-5.1, 2026-09-05 — Grounding footer scoped to "your conversation" (#193 review:
//  weight downloads reach the internet too, so "the only thing" overclaimed).
//  Review: Kev + claude-fable-5.1, 2026-09-03 — the Voice section (VoiceOutputSection: Built-in vs M1K3 Voice) joins
//  the face and the brain — mind, face, voice, the Mac's M1K3 tab.
//

import M1K3BrainLink
import M1K3Inference
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppCore.self) private var core
    @AppStorage(AppCore.webSearchEnabledKey) private var webSearchEnabled = true
    @AppStorage(ReadingMode.storageKey) private var readingModeRaw = ReadingMode.standard.rawValue
    @AppStorage(AppCore.avatarBackdropKey) private var avatarBackdrop = true

    /// Mobile-safe tiers only (see file header).
    private let brains: [BrainTier] = [.mini, .lil]

    var body: some View {
        Form {
            Section("Workspace") {
                NavigationLink {
                    MemoriesScreen()
                } label: {
                    Label("Memories", systemImage: "brain")
                }
                NavigationLink {
                    DocumentsScreen()
                } label: {
                    // The indexed count rides the row — it was a one-row
                    // "Knowledge" section of its own (cut 2026-09-03).
                    LabeledContent {
                        Text("\(core.indexedItemCount)")
                    } label: {
                        Label("Documents", systemImage: "doc.text")
                    }
                }
            }

            Section("Brain") {
                ForEach(brains) { tier in
                    Button {
                        core.selectBrain(tier)
                    } label: {
                        HStack(spacing: 12) {
                            // `glyph` is an SF Symbol NAME, not an emoji.
                            Image(systemName: tier.glyph)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tier.displayName).foregroundStyle(.primary)
                                Text(tier.tagline)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let floor = AppCore.lockedFloor(tier) {
                                Text(AppCore.lockedFloorLabel(floor))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            } else if core.selectedBrain == tier, !core.homeBrainActive {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(AppCore.lockedFloor(tier) != nil)
                }
                if let brain = core.homeBrain {
                    homeBrainRow(brain)
                }
                if let note = core.brainNote {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
                if let hint = miniHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }

            BrainAtHomeSection()

            CompanionPickerSection()

            VoiceOutputSection()

            Section {
                Toggle("Web search in chat", isOn: $webSearchEnabled)
            } header: {
                Text("Grounding")
            } footer: {
                // "Your conversation", not "the only thing that reaches the internet":
                // brain and M1K3 Voice downloads reach the internet too; Brain at Home
                // (above) sends prompts to your own Mac. Review catches, 2026-09-03/05.
                Text("The only thing that sends your conversation to the internet. "
                    + "Every search shows in the reply as it happens.")
            }

            Section {
                Toggle("Avatar backdrop in chat", isOn: $avatarBackdrop)
            } header: {
                Text("Appearance")
            } footer: {
                Text("M1K3's face fills the background while you chat. Reduce Transparency also turns it off.")
            }

            Section {
                Picker("Reply typeface", selection: $readingModeRaw) {
                    ForEach(ReadingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                ReadingText("Reading should feel effortless.")
                    .font(.callout)
            } header: {
                Text("Reading")
            } footer: {
                Text(readingMode.detail)
            }

            Section {
                LabeledContent("Version", value: appVersion)
                Link("m1k3.app", destination: URL(string: "https://m1k3.app")!)
            } header: {
                Text("About")
            } footer: {
                Text("Everything runs on your device.")
            }
        }
        .navigationTitle("Settings")
    }

    /// The Home tier row: the paired Mac's brain, selectable like a tier.
    private func homeBrainRow(_ brain: PairedBrain) -> some View {
        Button {
            core.selectHomeBrain()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "house")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Home").foregroundStyle(.primary)
                    Text("\(brain.name)’s brain, over your Wi-Fi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if core.homeBrainActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var readingMode: ReadingMode {
        ReadingMode(rawValue: readingModeRaw) ?? .standard
    }

    private var miniHint: String? {
        guard core.selectedBrain == .mini else { return nil }
        switch core.miniAvailability {
        case .available: return nil
        case .notReady: return "Apple Intelligence is still downloading on this device."
        case let .blocked(userFixable):
            return userFixable
                ? "Turn on Apple Intelligence in Settings, or choose Lil."
                : "This device can't run Apple Intelligence — choose Lil."
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
