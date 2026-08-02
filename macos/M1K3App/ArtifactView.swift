//
//  ArtifactView.swift
//  M1K3App
//
//  The renderer for code artifacts M1K3's brain generates. Two tabs — Preview
//  (live WKWebView) and Code (syntax-highlighted source) — plus an Export
//  button. The WebView uses a non-persistent data store (same privacy stance
//  as WebReviewView), and loads the HTML string directly rather than from a URL.

import AppKit
import M1K3Preview
import os
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ArtifactView: View {
    let artifact: CodeArtifact

    enum Tab: String, CaseIterable {
        case preview = "Preview"
        case code = "Code"
    }

    @State private var selectedTab: Tab
    @State private var showExporter = false

    init(artifact: CodeArtifact) {
        self.artifact = artifact
        // Code (python, swift, css, js…) opens straight to the source; only html and
        // markdown have a meaningful live Preview.
        _selectedTab = State(initialValue: artifact.language.isRenderable ? .preview : .code)
    }

    /// Preview is only offered for renderable languages; code opens to source only.
    private var tabs: [Tab] {
        artifact.language.isRenderable ? Tab.allCases : [.code]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            switch selectedTab {
            case .preview:
                // Markdown renders to HTML (previewHTML); html/css/js preview their
                // own source. The Code tab always shows the raw `source`.
                ArtifactPreviewWebView(source: artifact.previewHTML)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .code:
                codeView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: ArtifactDocument(artifact: artifact),
            contentType: artifact.language.utType,
            defaultFilename: artifact.filename
        ) { _ in }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if tabs.count > 1 {
                Picker("", selection: $selectedTab) {
                    ForEach(tabs, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }

            Spacer()

            Text(artifact.displayTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                showExporter = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Export \(artifact.filename)")

            // `message:` (not appended to `item`) so the shared source stays
            // byte-for-byte pasteable — corrupting it with trailing prose would
            // defeat the point of sharing code.
            ShareLink(
                item: artifact.source,
                subject: Text(artifact.displayTitle),
                message: Text("Shared from M1K3 · m1k3.app")
            ) {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Share \(artifact.filename)")
            .accessibilityLabel("Share \(artifact.filename)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var codeView: some View {
        ScrollView {
            Text(artifact.source)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(.background.opacity(0.5))
    }
}

// MARK: - WKWebView for artifact preview

private struct ArtifactPreviewWebView: NSViewRepresentable {
    let source: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // The preview renders UNTRUSTED, model-generated HTML. Disable JavaScript
        // outright: with no script there is no fetch/WebSocket/XHR egress, which is
        // the amplifier that makes every other gap exploitable. A code PREVIEW does
        // not need to execute scripts to render its HTML/CSS.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Block ALL sub-resource loads (images, scripts, stylesheets, fetch/XHR).
        // The navigation delegate handles navigation-level requests synchronously;
        // the content rule list seals the sub-resource gap. The rule decisions live
        // in the tested ArtifactSandboxPolicy.
        let source = self.source
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: ArtifactSandboxPolicy.contentRuleListIdentifier,
            encodedContentRuleList: ArtifactSandboxPolicy.contentRuleListJSON
        ) { list, error in
            Task { @MainActor in
                if let list {
                    webView.configuration.userContentController.add(list)
                    webView.loadHTMLString(source, baseURL: nil)
                    // Breadcrumb on the SUCCESS path too. Without it, an empty
                    // `artifact-preview` log is ambiguous: it means either "the seal
                    // never failed" or "no artifact was ever previewed", and those
                    // demand opposite next moves. `.notice` because `.info`/`.debug`
                    // do not persist in OSLogStore.
                    Self.logger.notice("artifact preview sealed and loaded (\(source.count, privacy: .public) bytes)")
                } else {
                    // Fail CLOSED: if the seal won't compile, do NOT load the content with
                    // only the navigation delegate (which does not see sub-resource loads).
                    // Show an honest placeholder instead of a silently un-sealed preview.
                    Self.logger.error(
                        "\(ArtifactFallback.diagnosticCode, privacy: .public) artifact preview seal failed to compile; refusing to load unsealed content: \(String(describing: error), privacy: .public)"
                    )
                    webView.loadHTMLString(ArtifactFallback.sealFailureHTML, baseURL: nil)
                }
            }
        }

        return webView
    }

    private static let logger = Logger(subsystem: "app.m1k3", category: "artifact-preview")

    func updateNSView(_: WKWebView, context _: Context) {
        // source is immutable (let); identity is managed by .id(artifact.createdAt) in the parent.
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
        {
            let allowed = ArtifactSandboxPolicy.allowsNavigation(scheme: action.request.url?.scheme)
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}

// MARK: - FileDocument for export

struct ArtifactDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        []
    }

    let artifact: CodeArtifact

    init(artifact: CodeArtifact) {
        self.artifact = artifact
    }

    init(configuration _: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnknown)
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        guard let data = artifact.exportData else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Previews

//
// ArtifactView is one of the cheapest views in the app to preview: it needs only
// M1K3Preview (a pure module) + WebKit, no AppEnvironment, no model, no MLX. That
// makes the canvas the fastest way to iterate on the house sheet — a CSS change
// and a redraw, instead of ⌘R and a chat turn that happens to emit an artifact.
//
// These deliberately include the FAILURE state. A failure you can only reach by
// breaking the sandbox at runtime is a failure nobody reviews, which is how the
// old white-page placeholder survived as long as it did.

#Preview("HTML artifact — the house sheet") {
    ArtifactView(artifact: CodeArtifact(
        source: """
        <h1>Tide Tables</h1>
        <p>An unstyled semantic document. Everything below is plain HTML — no
        classes, no framework — so what you see is the house sheet doing its job.</p>
        <h2>Method</h2>
        <p>Readings were taken hourly. The second paragraph should carry a LaTeX-style
        indent, and this prose should be justified and hyphenated on a comfortable measure.</p>
        <table>
          <thead><tr><th>Hour</th><th>Height</th></tr></thead>
          <tbody><tr><td>06:00</td><td>1.2 m</td></tr><tr><td>12:00</td><td>3.4 m</td></tr></tbody>
        </table>
        """,
        language: .html,
        title: "Tide Tables"
    ))
    .frame(width: 760, height: 620)
}

#Preview("Markdown artifact") {
    ArtifactView(artifact: CodeArtifact(
        source: "# Notes\n\nMarkdown rides the *same* sheet — one design language.\n",
        language: .markdown,
        title: "Notes",
        previewSource: ArtifactFormatter.formatMarkdown("# Notes\n\nMarkdown rides the *same* sheet — one design language.\n")
    ))
    .frame(width: 760, height: 620)
}

#Preview("Code artifact — opens to source, no Preview tab") {
    ArtifactView(artifact: CodeArtifact(
        source: "def tide(hour: int) -> float:\n    return 1.2 if hour < 9 else 3.4\n",
        language: .code,
        title: "tide",
        languageLabel: "python"
    ))
    .frame(width: 760, height: 620)
}

#Preview("Seal failure — what a fail-closed preview looks like") {
    // Renders the placeholder directly rather than sabotaging the sandbox, so the
    // failure state is reviewable design work like any other screen.
    ArtifactView(artifact: CodeArtifact(
        source: ArtifactFallback.sealFailureHTML,
        language: .html,
        title: "Preview held back"
    ))
    .frame(width: 760, height: 620)
}
