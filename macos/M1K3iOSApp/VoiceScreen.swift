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
//  Review: Kev + claude-fable-5.1, 2026-09-03 — the voice-first pass: the
//  spoken line is now the Mac's KaraokeReadingText (follow-the-word Focus
//  reader) over a timeline of fading spoken bubbles; the thinking caption
//  names the live activity (tool in flight) instead of a flat "Thinking…";
//  mic button mutes while listening; a tap on the face wakes a parked loop;
//  first streamed tokens bump the avatar thinking → generating; an
//  interruption's pause note replaces the idle caption. Same day, later: the
//  parked caption reads "carry on" — the mode is hands-free, and parking now
//  takes a long quiet spell (EndpointCadence.emptyListensBeforeParking), not
//  a few seconds. And the bubble timeline no longer wipes itself at every
//  sentence boundary (the per-chunk nil hop); it resets on a new answer.
//

import M1K3Avatar
import M1K3Chat
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
        // While awaiting the answer, the first streamed tokens bump thinking →
        // generating (observable signal — no timer). Same as the Mac.
        .onChange(of: core.chat.messages.last?.text) {
            bumpToGeneratingIfStreaming()
        }
        // The timeline: when the spoken utterance advances (sentence-streamed
        // lane) the finished line becomes a fading bubble behind the live one.
        // `clear()` fires after EVERY chunk (one utterance per sentence), so
        // the nil hop is a sentence boundary, not the end of the answer — a
        // wipe keyed on it erased each bubble before its first frame (three
        // reviews, 2026-09-03). Bubbles expire on their own clock; the
        // timeline resets when a NEW answer starts.
        .onChange(of: core.speechHighlight.utteranceText) { oldText, newText in
            if let oldText, !oldText.isEmpty, oldText != newText {
                retireSpokenBubble(oldText)
            }
        }
        .onChange(of: state) { _, newState in
            if case .awaitingAnswer = newState { spokenBubbles.removeAll() }
        }
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
        .onTapGesture { primaryAction() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityStateLabel)
        .accessibilityHint("Double-tap to start talking, or to interrupt while M1K3 is speaking.")
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
            if case .speaking = state {
                spokenTimeline
            } else {
                Text(captionText)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .animation(.easeInOut(duration: 0.15), value: captionText)
            }
            if let error = core.voiceLoop?.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            // Teach the spoken submit button (PoliteEndpoint): end on "please"
            // and M1K3 takes its turn on the short window.
            if case .listening = state {
                Text(PoliteEndpoint.uiHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 32)
        .frame(minHeight: 96, alignment: .top)
    }

    private var captionText: String {
        switch state {
        case .idle:
            // Parked (a long quiet spell, a failure, or not yet awake) — the
            // mode is hands-free, so this reads as "carry on", never "talk".
            core.voicePauseNote ?? "Tap the face to carry on."
        case let .listening(partial):
            partial.isEmpty ? "Listening…" : partial
        case .awaitingAnswer:
            // The live activity (a tool in flight) beats a flat "Thinking…" —
            // the Mac shows the same label.
            core.chat.messages.last?.activityLabel ?? "Thinking…"
        case .speaking:
            "" // unreachable by construction: `caption` renders spokenTimeline here
        case .ended:
            ""
        }
    }

    // MARK: - Spoken timeline (the Mac's bubbles, phone-sized)

    private struct SpokenBubble: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    @State private var spokenBubbles: [SpokenBubble] = []

    /// Already-spoken sentences dim and fade above the live one; the live
    /// bubble keeps the dyslexia Focus-reader following word-by-word.
    private var spokenTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(spokenBubbles) { bubble in
                Text(bubble.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .m1k3Glass(cornerRadius: 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let text = core.speechHighlight.utteranceText {
                KaraokeReadingText(
                    text: text,
                    timeline: core.speechHighlight.timeline,
                    currentWordRange: core.speechHighlight.currentWordRange,
                    compact: true
                )
                .frame(maxHeight: 165)
                .clipped()
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .m1k3Glass(cornerRadius: 18)
                .accessibilityLabel("M1K3 is speaking")
            } else if spokenBubbles.isEmpty {
                Text("Speaking…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.easeOut(duration: 0.3), value: spokenBubbles)
    }

    /// A finished line drifts into the timeline and fades out after a beat —
    /// spoken words leave the stage; the transcript keeps the record.
    private func retireSpokenBubble(_ text: String) {
        let bubble = SpokenBubble(text: text)
        withAnimation(.easeOut(duration: 0.3)) {
            spokenBubbles.append(bubble)
            if spokenBubbles.count > 2 { spokenBubbles.removeFirst() }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.9)) {
                spokenBubbles.removeAll { $0.id == bubble.id }
            }
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
            // Parked (muted, empty listens, an interruption, or an error) —
            // tap-to-talk re-arms and clears any pause note.
            Button {
                core.resumeVoiceListening()
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
        case .listening:
            // Mute parks the mic without leaving the mode (the Mac's mic button).
            Button {
                core.voiceLoop?.mute()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.red)
                    .symbolEffect(.breathe, isActive: true)
                    .padding(22)
                    .m1k3Glass(cornerRadius: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mute microphone")
        case .awaitingAnswer, .ended:
            // The live states carry their own feedback; no extra chrome.
            Color.clear.frame(height: 52)
        }
    }

    /// Tap the face: wake from a parked idle, or barge in while M1K3 speaks.
    private func primaryAction() {
        switch state {
        case .idle: core.resumeVoiceListening()
        case .speaking: bargeIn()
        default: break // listening / thinking: no-op (v1)
        }
    }

    /// While awaiting the answer, the first streamed tokens bump thinking →
    /// generating (observable signal — no timer).
    private func bumpToGeneratingIfStreaming() {
        guard case .awaitingAnswer = state,
              let last = core.chat.messages.last,
              last.role == .assistant, !last.text.isEmpty
        else { return }
        core.avatar.setActivity(.generating)
    }

    /// Barge-in: only meaningful while speaking (the machine ignores it
    /// elsewhere, but gating here keeps stray taps from surprising the loop).
    private func bargeIn() {
        guard case .speaking = state else { return }
        core.voiceLoop?.interrupt()
    }
}
