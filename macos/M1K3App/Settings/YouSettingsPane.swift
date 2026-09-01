//
//  YouSettingsPane.swift
//  M1K3App
//
//  The "You" Settings tab: the persona's About-you block, memory consent +
//  review, and how M1K3's replies are typeset. Split out of the old
//  single-Form SettingsView (2026-07-13) — see SettingsView.swift for the
//  shell.
//
//  Signed: Kev + claude-fable-5, 2026-07-13, Confidence 0.85 (a straight move
//  — every footer/copy verbatim). Prior: Kev + claude-opus-4-8
//  (SettingsView.swift lineage, 2026-06-06).
//

import M1K3Inference
import SwiftUI

struct YouSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(AppEnvironment.memoryAutoCaptureKey) private var memoryAutoCapture = true
    @AppStorage(ReadingMode.storageKey) private var readingMode: ReadingMode = .standard
    @State private var showMemories = false
    @State private var profileDraft = ""

    var body: some View {
        Form {
            aboutYouSection

            memorySection

            Section {
                Picker("Reading mode", selection: $readingMode) {
                    ForEach(ReadingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(readingMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Live preview in the chosen mode.
                ReadingText("M1K3 keeps your words on this Mac — ask it anything.",
                            mode: readingMode)
                    .padding(.vertical, 4)
            } header: {
                Text("Reading")
            } footer: {
                Text("How M1K3's replies are typeset. Dyslexia-friendly uses OpenDyslexic; "
                    + "Bionic reader bolds the start of each word to guide the eye.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// The consent surface for the persona's About-the-user block: fully
    /// visible, editable, clearable.
    private var aboutYouSection: some View {
        Section {
            TextField(
                "Tell M1K3 who you are",
                text: $profileDraft,
                axis: .vertical
            )
            .lineLimit(2 ... 5)
            .onSubmit { env.saveUserProfile(profileDraft) }
            HStack {
                Button("Save") { env.saveUserProfile(profileDraft) }
                    .buttonStyle(.glass)
                    .disabled(profileDraft == (M1K3Persona.userProfile ?? ""))
                Button("Clear", role: .destructive) {
                    profileDraft = ""
                    env.saveUserProfile(nil)
                }
                .buttonStyle(.glass)
                .disabled((M1K3Persona.userProfile ?? "").isEmpty)
            }
        } header: {
            Text("About you")
        } footer: {
            Text("What M1K3 knows about you — it rides every conversation's "
                + "system prompt. Stored on this machine only, never retrieved or "
                + "cited, yours to edit or clear.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { profileDraft = M1K3Persona.userProfile ?? "" }
    }

    /// Memory auto-capture consent + the door to the review/forget surface.
    private var memorySection: some View {
        Section {
            Toggle("Learn from conversations", isOn: $memoryAutoCapture)
            Button("View memories…") { showMemories = true }
                .buttonStyle(.glass)
        } header: {
            Text("Memories")
        } footer: {
            Text("M1K3 extracts durable facts about you — preferences, decisions, "
                + "people — from conversations, on-device. Review and erase anytime.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showMemories) {
            MemoriesView().environment(env)
        }
    }
}
