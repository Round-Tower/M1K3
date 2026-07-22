//
//  CodeBlockView.swift
//  M1K3App
//
//  Renders one fenced code block (ChatMarkdownBlock.codeBlock) as an actual
//  code card — monospaced, lightly syntax-highlighted (CodeSyntaxHighlighter,
//  a local token kind → no external highlighting lib, no network), with a
//  language label and a copy button — instead of the raw ```lang…``` text a
//  chat bubble used to show verbatim. Shared with the iOS/visionOS shell (see
//  project.yml's MobileShell sources) via #if canImport, same house rule as
//  AvatarView's cross-platform accent-colour extraction.
//
//  Signed: Kev + claude-sonnet-5, 2026-07-22, Confidence 0.8, Prior: Unknown

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif
import M1K3Chat
import SwiftUI

struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.15)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            copyButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var copyButton: some View {
        Button(action: copyCode) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Copy code")
        .help(didCopy ? "Copied" : "Copy code")
    }

    private func copyCode() {
        #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        #elseif canImport(UIKit)
            UIPasteboard.general.string = code
        #endif
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            didCopy = false
        }
    }

    /// Maps CodeSyntaxHighlighter's pure token kinds onto colour. Independent
    /// of ReadingMode — code always stays monospaced/plain-colour-scheme
    /// regardless of the reading-accessibility mode active for prose.
    private var highlighted: AttributedString {
        var result = AttributedString()
        for token in CodeSyntaxHighlighter.tokenize(code, language: language) {
            var run = AttributedString(token.text)
            run.foregroundColor = color(for: token.kind)
            if token.kind == .comment {
                run.font = .system(.callout, design: .monospaced).italic()
            }
            result += run
        }
        return result
    }

    private func color(for kind: CodeTokenKind) -> Color {
        switch kind {
        case .keyword: .pink
        case .string: .green
        case .comment: .secondary
        case .number: .orange
        case .type: .cyan
        case .plain: .primary
        }
    }
}

#Preview {
    CodeBlockView(
        code: "func greet(name: String) -> String {\n    // a friendly hello\n    return \"Hi \\(name)\"\n}",
        language: "swift"
    )
    .padding()
}
