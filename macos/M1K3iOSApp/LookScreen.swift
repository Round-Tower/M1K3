//
//  LookScreen.swift
//  M1K3iOS / M1K3visionOS
//
//  Point the phone at something and ask (#768). The viewfinder fills the
//  screen; the field takes a question (empty asks "What am I looking at?");
//  each ask takes a new frame and the answer streams in over the view. Every
//  look is also a turn in the chat underneath, so closing the screen loses
//  nothing. The camera is on only while this screen is up.
//
//  The answer sits on material, not glass: it changes on every token, and
//  nothing that ticks goes inside glass (the #78 crash rule).
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.6, Prior: none (new file)
//  Open: the layout is compile-checked only until it has been in Kev's hand.
//  Review: Kev + claude-fable-5.2, 2026-11-09 (review fold) — one `.task(id:
//  scenePhase)` opens the camera, so a return-to-foreground open cannot start
//  after the screen's close; a camera iOS took away shows a way back instead of
//  a spinner; the ask is off while a look is taking its frame.
//

import M1K3Chat
import SwiftUI

struct LookScreen: View {
    @Environment(AppCore.self) private var core
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var question = ""
    /// The chat's length when this screen opened: only turns after it are shown here.
    @State private var baseline: Int?
    @FocusState private var questionFocused: Bool

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            viewfinder
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Spacer()
                answerCaption
                askBar
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: 760)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(12)
                    .m1k3Glass(cornerRadius: 22)
            }
            .buttonStyle(.plain)
            .padding(20)
            .accessibilityLabel("Close the camera")
        }
        .preferredColorScheme(.dark)
        // The camera is on only while this screen is up and the app is in
        // front: the task opens it on arrival and again on each return to the
        // foreground (the camera closes itself in the background), and is
        // cancelled with the screen, so no open can start after the close below.
        // It re-runs on every return to active; `open()` is idempotent, so an
        // already-open camera is left alone.
        .task(id: scenePhase) {
            if baseline == nil { baseline = core.chat.messages.count }
            guard scenePhase == .active, !Task.isCancelled else { return }
            _ = await core.lookCamera.open()
        }
        .onDisappear {
            core.lookCamera.close()
        }
    }

    // MARK: - Viewfinder

    @ViewBuilder
    private var viewfinder: some View {
        switch core.lookCamera.state {
        case .open:
            LookPreview(camera: core.lookCamera)
                .accessibilityLabel("Camera view")
        case .opening:
            ProgressView()
                .accessibilityLabel("Opening the camera")
        case .closed:
            // iOS took the camera away (a call, another app) and gave no way back by itself.
            Button {
                Task { _ = await core.lookCamera.open() }
            } label: {
                Label("Open the camera", systemImage: "eye")
                    .padding(24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        case .denied:
            notice("Camera access is off for M1K3.", settingsLink: true)
        case .restricted:
            notice("The camera is restricted on this device.", settingsLink: false)
        case .unavailable:
            notice("This device has no camera M1K3 can use.", settingsLink: false)
        }
    }

    private func notice(_ text: LocalizedStringKey, settingsLink: Bool) -> some View {
        VStack(spacing: 12) {
            Label(text, systemImage: "eye.slash")
                .foregroundStyle(.secondary)
            #if os(iOS)
                if settingsLink, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Allow the camera in Settings", destination: url)
                }
            #endif
        }
        .padding(24)
    }

    // MARK: - Answer

    /// This screen's newest answer: the last assistant message since it opened.
    private var answer: ChatMessage? {
        guard let baseline, core.chat.messages.count > baseline,
              let last = core.chat.messages.last, last.role == .assistant
        else { return nil }
        return last
    }

    @ViewBuilder
    private var answerCaption: some View {
        if let answer {
            ScrollView {
                Text(answer.text.isEmpty ? String(localized: "Looking…") : answer.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 18))
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    // MARK: - Ask

    private var stoppable: Bool {
        core.chat.isResponding || core.isSpeakingAnswer
    }

    private var canAsk: Bool {
        core.lookCamera.isOpen && core.isReady && core.canLook && !core.chat.isResponding && !core.isLooking
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about what you see…", text: $question, axis: .vertical)
                .lineLimit(1 ... 3)
                .focused($questionFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .m1k3Glass(cornerRadius: 22)
                .onSubmit(ask)

            Button {
                if stoppable { core.stopResponding() } else { ask() }
            } label: {
                Image(systemName: stoppable ? "stop.circle.fill" : "eye.circle.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(stoppable ? .red : .accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!canAsk && !stoppable)
            .accessibilityLabel(
                core.chat.isResponding ? "Stop generating" : core.isSpeakingAnswer ? "Stop speaking" : "Look"
            )
            .accessibilityHint("M1K3 looks at what the camera sees and answers on this device")
        }
    }

    private func ask() {
        guard canAsk else { return }
        let asked = question
        question = ""
        questionFocused = false
        Task { await core.look(asked) }
    }
}
