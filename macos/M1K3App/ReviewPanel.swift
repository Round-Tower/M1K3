//
//  ReviewPanel.swift
//  M1K3App
//
//  The in-window review surface (a trailing inspector): paste a link, drop a file,
//  or pick one — and review it beside the conversation without leaving M1K3. Web
//  links open in an embedded WKWebView; local files render through QuickLook.
//
//  State lives in the shared ReviewModel (AppEnvironment), so a chat link-chip, the
//  MCP `open_link` tool, and M1K3's own agent can all drive this same panel. The
//  routing brain is the pure ReviewTargetResolver (M1K3Preview, fully tested); this
//  view is the glass-styled shell around it.
//
//  Once file tools land, a code file is just a `.file` target — QuickLook already
//  syntax-highlights source — so the panel grows into a code reviewer for free.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-19, Confidence 0.8, Prior: Unknown

import AppKit
import M1K3Preview
import SwiftUI
import UniformTypeIdentifiers

struct ReviewPanel: View {
    let review: ReviewModel

    @State private var isDropTargeted = false
    @State private var showImporter = false

    var body: some View {
        @Bindable var review = review
        return VStack(spacing: 0) {
            addressBar
            Divider().opacity(0.4)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glassBackdrop()
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            review.open(url: url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                review.open(url: url)
            }
        }
    }

    // MARK: - Address bar

    /// One adaptive, roomy row — no second nav bar, no duplicated URL. The single
    /// bar collapses the old two-row header (that's the cognitive-load win), but
    /// it's given generous breathing room and full-size controls so it reads as
    /// calm and premium, not a cramped strip. Contextual actions appear only when
    /// they apply (open-in-browser for a web page), so the resting state is just an
    /// icon and the address field.
    private var addressBar: some View {
        @Bindable var review = review
        return HStack(spacing: 12) {
            Image(systemName: addressIcon)
                .foregroundStyle(.secondary)
                .font(.title3)
            TextField("Paste a link or path…", text: $review.input)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit { review.openTyped() }
            if !review.input.isEmpty {
                Button { review.clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            if let url = review.currentWebURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "safari")
                }
                .help("Open in browser")
            }
            Button { showImporter = true } label: {
                Image(systemName: "folder")
            }
            .help("Choose a file to review")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // The three heavy cases mount hosted AppKit views (WKWebView /
        // QLPreviewView) behind DeferredPanelMount — the #79 fix: their first
        // layout must land OUTSIDE the inspector's constraint pass or AppKit
        // aborts the process (see DeferredPanelMount.swift for the stack).
        switch review.target {
        case .empty:
            placeholder
        case let .web(url):
            DeferredPanelMount { WebReviewView(url: url) { review.setPageContext($0, for: url) } }
                .id(url)
        case let .file(url):
            DeferredPanelMount { QuickLookPreview(url: url) }
                .id(url)
        case let .artifact(artifact):
            DeferredPanelMount { ArtifactView(artifact: artifact) }
                .id(artifact.createdAt)
        case let .invalid(raw):
            ContentUnavailableView {
                Label("Couldn't open that", systemImage: "questionmark.square.dashed")
            } description: {
                Text("\"\(raw)\" isn't a link or a readable file. Paste an http(s) link, or drop / choose a file.")
            }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("Review panel", systemImage: "sidebar.right")
        } description: {
            Text("Paste a link, or drop a file here, to review it beside the conversation.")
        }
    }

    /// Leading icon reflects what's loaded: a link, a document, or a problem.
    private var addressIcon: String {
        switch review.target {
        case .file: "doc"
        case .artifact: "curlybraces"
        case .invalid: "exclamationmark.triangle"
        case .empty, .web: "globe"
        }
    }
}
