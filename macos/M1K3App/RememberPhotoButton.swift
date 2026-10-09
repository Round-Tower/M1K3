//
//  RememberPhotoButton.swift
//  M1K3
//
//  "Remember this photo" under a sent image -- shared by the Mac message view and
//  the iOS bubble (the MobileShell template lists this file). One tap captions
//  the picture on the selected brain and files the caption as a Photo memory;
//  the tap is also the consent. States: the action, a visible "Looking...", a
//  "Remembered" confirmation, and a failure that names why (a Mini or Pocket
//  brain is refused by name: "Switch to Lil to remember photos").
//
//  The model, rules and policy live in M1K3Chat (PhotoMemory / ImageCaptionPolicy,
//  unit-tested); this view only draws them. Verify-by-launch.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.7 (pure SwiftUI over a
//  tested model; TDD_SKIP). Prior: Unknown

import M1K3Chat
import M1K3Inference
import SwiftUI

private struct PhotoMemoryKey: EnvironmentKey {
    static let defaultValue: PhotoMemory? = nil
}

extension EnvironmentValues {
    /// The shell's PhotoMemory; nil (no button) where a surface has none.
    var photoMemory: PhotoMemory? {
        get { self[PhotoMemoryKey.self] }
        set { self[PhotoMemoryKey.self] = newValue }
    }
}

struct RememberPhotoButton: View {
    let attachment: ImageAttachment
    @Environment(\.photoMemory) private var memory

    var body: some View {
        if let memory {
            content(memory.state(for: attachment), memory: memory)
                .font(.caption)
        }
    }

    @ViewBuilder
    private func content(_ state: PhotoMemory.State?, memory: PhotoMemory) -> some View {
        switch state {
        case .looking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking…")
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Looking at the photo"))
        case .remembered:
            Label("Remembered on this device", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Photo remembered. The caption stays on this device."))
        case let .failed(message):
            VStack(alignment: .trailing, spacing: 2) {
                action(memory, title: String(localized: "Try again"))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        case nil:
            action(memory, title: String(localized: "Remember this photo"))
        }
    }

    private func action(_ memory: PhotoMemory, title: String) -> some View {
        Button {
            Task { await memory.remember(attachment) }
        } label: {
            Label(title, systemImage: "photo.badge.plus")
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Write a short description of this photo and remember it. The description stays on this device."))
        .accessibilityHint(String(localized: "Writes a short description and remembers it on this device"))
    }
}
