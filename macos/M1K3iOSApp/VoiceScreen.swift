//
//  VoiceScreen.swift
//  M1K3iOS / M1K3visionOS
//
//  Voice-first mode, full screen: the avatar IS the interface. A big live face
//  (or a pulsing waveform when the None companion is chosen), one caption line
//  that tracks the loop state — the live partial while listening, thinking,
//  speaking — and two glass controls: tap the face to barge in, X to leave.
//  Everything routes through the package-TDD'd VoiceLoopController the Mac
//  ships; this view renders its state and forwards intents.
//
//  Signed: Kev + claude-fable-5, 2026-07-29, Confidence 0.75 (pure rendering of
//  test-pinned loop state; the felt beat — echo, endpointing, barge-in — is
//  verify-by-launch on a real device). Prior: none (new file, patterned on the
//  Mac's VoiceModeView).
//

import M1K3Avatar
import M1K3Voice
import SwiftUI

struct VoiceScreen: View {
    @Environment(AppCore.self) private var core
    @AppStorage(CompanionDefaults.companionKey) private var companion = ""

    private var state: VoiceLoopState {
        core.voiceLoop?.state ?? .ended
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.11), .black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 12)
                face
                caption
                Spacer()
                controls
            }
            .padding(.bottom, 36)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                core.exitVoiceMode()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(12)
                    .m1k3Glass(cornerRadius: 22)
            }
            .buttonStyle(.plain)
            .padding(20)
            .accessibilityLabel("Leave voice mode")
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - The face

    private var face: some View {
        Group {
            if CompanionDefaults.hidesAvatar(companion) {
                // The None companion: a quiet waveform stands in so the mode
                // still has a visual anchor for its state.
                Image(systemName: "waveform")
                    .font(.system(size: 96, weight: .light))
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: isLive)
                    .frame(maxHeight: 320)
            } else {
                AvatarSurface(controller: core.avatar)
                    .frame(maxHeight: 340)
                    .padding(.horizontal, 44)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture { bargeIn() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityStateLabel)
        .accessibilityHint("Double-tap to interrupt while M1K3 is speaking.")
    }

    /// Mic or speech actively moving — drives the waveform's variable-color pulse.
    private var isLive: Bool {
        switch state {
        case .listening, .speaking: true
        case .idle, .awaitingAnswer, .ended: false
        }
    }

    // MARK: - Caption

    private var caption: some View {
        VStack(spacing: 10) {
            Text(captionText)
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .animation(.easeInOut(duration: 0.15), value: captionText)
            if let error = core.voiceLoop?.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .frame(minHeight: 96, alignment: .top)
    }

    private var captionText: String {
        switch state {
        case .idle:
            "Tap the mic to talk"
        case let .listening(partial):
            partial.isEmpty ? "Listening…" : partial
        case .awaitingAnswer:
            "Thinking…"
        case let .speaking(answer):
            answer
        case .ended:
            ""
        }
    }

    private var accessibilityStateLabel: String {
        switch state {
        case .idle: "Voice mode, microphone parked"
        case .listening: "Listening"
        case .awaitingAnswer: "Thinking"
        case .speaking: "Speaking"
        case .ended: "Voice mode ended"
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .idle:
            // Parked (muted, empty listens, or an error) — tap-to-talk re-arms.
            Button {
                core.voiceLoop?.begin()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 26))
                    .padding(22)
                    .m1k3Glass(cornerRadius: 40, tint: .accentColor.opacity(0.25))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start listening")
        case .speaking:
            Button {
                bargeIn()
            } label: {
                Label("Interrupt", systemImage: "stop.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .m1k3Glass(cornerRadius: 24)
            }
            .buttonStyle(.plain)
        case .listening, .awaitingAnswer, .ended:
            // The live states carry their own feedback; no extra chrome.
            Color.clear.frame(height: 52)
        }
    }

    /// Barge-in: only meaningful while speaking (the machine ignores it
    /// elsewhere, but gating here keeps stray taps from surprising the loop).
    private func bargeIn() {
        guard case .speaking = state else { return }
        core.voiceLoop?.interrupt()
    }
}
