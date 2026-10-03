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
//  Review: Kev + claude-fable-5.1, 2026-09-05 — the Brain rows come from MobileBrainMenu (no Mini on a device that
//  can't run Apple Intelligence, no locked Lil rows, Home listed even before pairing); the hint names the real
//  alternative. Confidence now 0.85 (verify-by-launch on the iPad 8th gen + 17 Pro).
//  Review: Kev + claude-fable-5.1, 2026-09-06 — the blocked-Mini hint names pocket by what it is
//  (`localFallbackPhrase`) — "choose Mini" beside a Mini row was the one-Mini rule leaking into copy (PR #234
//  review 12). Confidence now 0.8.
//
//  Review: Kev + claude-fable-5.1, 2026-09-15 — About gains the manual Rate M1K3 door.
//  Review: Kev + claude-opus-4-6, 2026-09-19 — Content Controls section (DeclaredAgeRange
//  age-band wiring: Settings > Content Controls > system sheet, web-tool gating for under-16,
//  @preconcurrency import for the non-Sendable DeclaredAgeRangeAction). Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-10-01 — the entitlement this needed was never added
//  (M1K3iOS.entitlements has it now), and `catch {}` hid the refusal. A failed ask says why
//  (`AgeRangeRequestFailure`, tested) and leaves the band alone. Confidence 0.8 (verify on device).
//  Review: Kev + claude-opus-5-5, 2026-10-03 — Apple's error maps by case NAME: the switch over its cases
//  strong-linked its invalidAccount case, absent on iOS 26.5, and dyld killed the app at launch. Verified on the
//  26.5 simulator. Confidence 0.9.
//  Review: Kev + claude-opus-5-5, 2026-10-03 — under the privacy screengrab plate the form scrolls to Grounding
//  (the web-search switch) on appear; inert otherwise. Confidence 0.8 (verify-by-launch on the sim).

#if canImport(DeclaredAgeRange)
    @preconcurrency import DeclaredAgeRange
#endif
import M1K3BrainLink
import M1K3Chat
import M1K3Inference
import M1K3Screengrab
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppCore.self) private var core
    @AppStorage(AppCore.webSearchEnabledKey) private var webSearchEnabled = true
    @AppStorage(PersistedAgeBandProvider.defaultsKey) private var ageBandRaw: String?
    /// Why the last "Set up" came back without an answer — shown under the button.
    @State private var ageRangeFailure: AgeRangeRequestFailure?
    @AppStorage(ReadingMode.storageKey) private var readingModeRaw = ReadingMode.standard.rawValue
    @AppStorage(AppCore.avatarBackdropKey) private var avatarBackdrop = true

    /// What THIS device may list — Mini only where Apple Intelligence runs, Lil only
    /// above its memory floor, Brain at Home always (MobileBrainMenu).
    private var menu: MobileBrainMenu {
        core.brainMenu
    }

    private var brains: [BrainTier] {
        menu.options.compactMap { if case let .tier(tier) = $0 { tier } else { nil } }
    }

    var body: some View {
        ScrollViewReader { proxy in
            form
                .task {
                    // The privacy plate's subject is the web-search switch, below the fold.
                    if ScreengrabHarness.current.plate == .privacyLabel { proxy.scrollTo(Self.groundingID, anchor: .center) }
                }
        }
        .navigationTitle("Settings")
    }

    private static let groundingID = "grounding"

    private var form: some View {
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
                            if core.selectedBrain == tier, !core.homeBrainActive {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if let brain = core.homeBrain {
                    homeBrainRow(brain)
                } else {
                    pairRow
                }
                if let note = menu.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
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

            contentControlsSection

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
            .id(Self.groundingID)

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
                // The manual door beside the earned prompt (ReviewPromptPolicy) —
                // user-initiated, so it bypasses the ledger on purpose.
                Link(
                    "Rate M1K3 on the App Store",
                    destination: ReviewPromptPolicy.writeReviewURL(storefront: .appStore)
                )
            } header: {
                Text("About")
            } footer: {
                Text("Everything runs on your device.")
            }
        }
    }

    #if !os(visionOS)
        @Environment(\.requestAgeRange) private var requestAgeRange

        private var contentControlsSection: some View {
            let band = AgeBand(persisted: ageBandRaw)
            let active = band != .undeclared && band != .adult
            return Section {
                HStack {
                    Label(
                        active ? "Age-appropriate adjustments active" : "No age range declared",
                        systemImage: active ? "person.crop.circle.badge.checkmark" : "person.crop.circle"
                    )
                    Spacer()
                    if band != .undeclared {
                        Button("Clear") {
                            ageBandRaw = nil
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button(band == .undeclared ? "Set up" : "Update") {
                    requestAgeBand()
                }
                if let ageRangeFailure {
                    Label(ageRangeFailure.message, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Content Controls")
            } footer: {
                Text("Uses Apple's Declared Age Range to adjust content for younger users. "
                    + "Web search is disabled for under 16; the assistant's tone adjusts for all minors. "
                    + "Declining gives full capability.")
            }
        }

        private func requestAgeBand() {
            ageRangeFailure = nil
            Task { @MainActor in
                do {
                    let response = try await requestAgeRange(ageGates: 13, 16, 18)
                    switch response {
                    case .declinedSharing:
                        ageBandRaw = AgeBand.undeclared.rawValue
                    case let .sharing(range):
                        ageBandRaw = AgeBand(lowerBound: range.lowerBound, upperBound: range.upperBound).rawValue
                    @unknown default:
                        break
                    }
                } catch let error as AgeRangeService.Error {
                    ageRangeFailure = AgeRangeRequestFailure(error)
                } catch {
                    ageRangeFailure = .other
                }
            }
        }
    #else
        private var contentControlsSection: some View {
            EmptyView()
        }
    #endif

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

    /// Home before a Mac is paired: the same row shape, leading into the ceremony —
    /// on a device with no local brain this is the only row (QA pass, 2026-09-05).
    private var pairRow: some View {
        NavigationLink {
            BrainPairingScreen()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "house")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Home").foregroundStyle(.primary)
                    Text("Your Mac’s brain, over your Wi‑Fi — pair to use it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
            let alternative = menu.localFallbackPhrase(verb: "choose") ?? "use Home"
            return userFixable
                ? "Turn on Apple Intelligence in Settings, or \(alternative)."
                : "This device can't run Apple Intelligence — \(alternative)."
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#if canImport(DeclaredAgeRange) && !os(visionOS)
    extension AgeRangeRequestFailure {
        /// The boundary map: M1K3Chat never imports DeclaredAgeRange. (The Mac's
        /// twin lives in PrivacySettingsPane; the two shells share no app files.)
        init(_ error: AgeRangeService.Error) {
            // By NAME: a switch over Apple's
            // cases links each case symbol at launch, and an OS that predates
            // one (iOS 26.5, the iOS 27 beta) never starts the app (2026-10-03).
            self.init(appleCaseName: String(describing: error))
        }
    }
#endif
