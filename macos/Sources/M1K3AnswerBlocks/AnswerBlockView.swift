//
//  AnswerBlockView.swift
//  M1K3AnswerBlocks
//
//  The one renderer for typed answer blocks (#717), shared by the Mac app and the
//  iOS / visionOS shells through ReadingText. Plain cards (the CodeBlockView look)
//  and bordered buttons, never Liquid Glass: `glassEffect` is unavailable on
//  visionOS (GlassCompat.swift), and a shell can restyle later.
//
//  • Steps: numbered rows, each a toggle the user can tick. The ticks are
//    session-only `@State`; nothing is persisted, so a block is derived from the
//    message text alone, like the transient follow-up chips.
//  • Choices: the prompt, then one button per option. A tap calls the
//    environment's `answerChoiceAction` (the shell's follow-up send), so the
//    option lands as the user's next message. Without an action (a user bubble,
//    the reasoning panel, a turn still streaming) the buttons are disabled.
//  • Skeleton: a static placeholder while the fence is open. Static on purpose:
//    nothing ticks during a stream (the idle-CPU and glass rules).
//
//  Fonts come from the environment, so ReadingText's reading mode (serif,
//  OpenDyslexic) carries into the cards; only the step numbers set their own.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.7 (compiles for all three
//  shells; the look, the tap path and VoiceOver are verify-by-launch, owed to Kev).
//  Prior: none (new file).
//

import SwiftUI

/// Where a tapped choice goes: the shell's follow-up send, so the option lands
/// as the user's next message. A struct around the closure, like SwiftUI's own
/// `OpenURLAction`.
public struct AnswerChoiceAction {
    private let send: (String) -> Void

    public init(_ send: @escaping (String) -> Void) {
        self.send = send
    }

    public func callAsFunction(_ option: String) {
        send(option)
    }
}

public extension EnvironmentValues {
    /// Nil keeps a choices card read-only.
    @Entry var answerChoiceAction: AnswerChoiceAction? = nil
}

/// One parsed block as a card.
public struct AnswerBlockView: View {
    private let block: AnswerBlock

    public init(_ block: AnswerBlock) {
        self.block = block
    }

    public var body: some View {
        switch block {
        case let .steps(steps):
            StepsCard(steps: steps)
        case let .choices(prompt, options):
            ChoicesCard(prompt: prompt, options: options)
        }
    }
}

/// The placeholder for a typed fence that is still streaming.
public struct AnswerBlockSkeletonView: View {
    private let kind: AnswerBlockKind

    public init(kind: AnswerBlockKind) {
        self.kind = kind
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch kind {
            case .steps:
                ForEach(0 ..< 3, id: \.self) { _ in
                    HStack(spacing: 8) {
                        Image(systemName: "circle")
                        Text(verbatim: "A step that is still being written")
                    }
                }
            case .choices:
                Text(verbatim: "A question still being written")
                ForEach(0 ..< 2, id: \.self) { _ in
                    Text(verbatim: "An option")
                        .modifier(ChoiceChrome(isPressed: false))
                }
            }
        }
        .redacted(reason: .placeholder)
        .answerBlockCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AnswerBlockText.skeletonLabel(kind))
    }
}

private struct StepsCard: View {
    let steps: [String]
    @State private var done: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                row(index: index, step: step)
            }
        }
        .answerBlockCard()
    }

    private func row(index: Int, step: String) -> some View {
        let isDone = done.contains(index)
        return Button {
            if isDone { done.remove(index) } else { done.insert(index) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? Color.accentColor : Color.secondary)
                Text(verbatim: "\(index + 1).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(AnswerBlockText.inline(step))
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AnswerBlockText.stepLabel(number: index + 1, of: steps.count, step: step))
        .accessibilityValue(AnswerBlockText.stepValue(done: isDone))
        .accessibilityAddTraits(.isToggle)
    }
}

private struct ChoicesCard: View {
    let prompt: String
    let options: [String]
    @Environment(\.answerChoiceAction) private var choose
    /// The option tapped this session, marked so the tap reads as received.
    @State private var chosen: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AnswerBlockText.inline(prompt))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ForEach(options, id: \.self) { option in
                Button {
                    chosen = option
                    choose?(option)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if chosen == option {
                            Image(systemName: "checkmark")
                        }
                        Text(AnswerBlockText.inline(option))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(ChoiceButtonStyle())
                .disabled(choose == nil)
                .accessibilityLabel(AnswerBlockText.choiceLabel(option))
                .accessibilityHint(choose == nil ? "" : AnswerBlockText.choiceHint)
            }
        }
        .answerBlockCard()
    }
}

/// A bordered, wrapping button. Not the system `.bordered` style: on the Mac that
/// draws a one-line push button, and a 150-character option would force the
/// window wider (the issue #79 lesson ReadingText's tables learned).
private struct ChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ChoiceChrome(isPressed: configuration.isPressed))
    }
}

private struct ChoiceChrome: ViewModifier {
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    #if os(macOS)
        private let minHeight: CGFloat = 28
    #else
        private let minHeight: CGFloat = 44 // the touch target
    #endif

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: minHeight, alignment: .leading)
            .background(Color.accentColor.opacity(isPressed ? 0.22 : 0.1), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.4)))
            .contentShape(.rect(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.55)
    }
}

private extension View {
    /// The CodeBlockView card: a faint fill and hairline, spanning the bubble.
    func answerBlockCard() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.15)))
    }
}

#Preview("Steps and choices") {
    VStack(alignment: .leading, spacing: 12) {
        AnswerBlockView(.steps(["Loosen the **nut**.", "Lift the cover.", "Check the seal for cracks."]))
        AnswerBlockView(.choices(prompt: "Which engine?", options: ["Lil", "Big", "Mini"]))
        AnswerBlockSkeletonView(kind: .steps)
        AnswerBlockSkeletonView(kind: .choices)
    }
    .environment(\.answerChoiceAction, AnswerChoiceAction { _ in })
    .padding()
    .frame(width: 420)
}
