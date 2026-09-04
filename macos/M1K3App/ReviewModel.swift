//
//  ReviewModel.swift
//  M1K3App
//
//  The shared state behind the review panel, owned by AppEnvironment so every
//  surface that wants to surface a link or file converges here: the inspector
//  itself, a one-click chip in the chat transcript, the MCP `open_link` tool a
//  visiting agent calls, and M1K3's own local agent mid-answer. One observable,
//  one source of truth.
//
//  Holds the security-scoped grant for a file target and releases it when we move
//  off — so the sandbox access doesn't leak across opens.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-19, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-04 — the panel now tells the model what
//  it shows: `pageContext` (the rendered page's title + text, set by
//  WebReviewView on load) mirrors into a nonisolated `liveContext` snapshot the
//  agent responder reads each turn (BrowserContext). Cleared on every target
//  change, so a closed or replaced page never lingers in the prompt — and a
//  late arrival is checked against the page still on screen (`setPageContext`),
//  so a slow page's capture can't land on top of the page that replaced it.

import Foundation
import M1K3Chat
import M1K3Preview
import Synchronization

@MainActor
@Observable
final class ReviewModel {
    /// Whether the inspector is showing.
    var isPresented = false
    /// The address-bar text (bound by the panel).
    var input = ""
    /// What's currently routed for display.
    private(set) var target: ReviewTarget = .empty

    /// The live web URL, when a page is showing — for the "open in browser" action.
    var currentWebURL: URL? {
        if case let .web(url) = target { return url }
        return nil
    }

    /// The file URL we hold security-scoped access to (from a drop / open panel).
    private var scopedURL: URL?

    /// What the web view last finished rendering — nil unless a web page is
    /// showing. Mirrors into `liveContext` for the (non-main-actor) responder.
    private(set) var pageContext: BrowserContext? {
        didSet { Self.liveContext.withLock { $0 = pageContext } }
    }

    /// Accept a finished page's context only while `requested` is still the
    /// page on screen. The web view is keyed by the REQUESTED url, so a capture
    /// that completes after the panel moved on (a second open_link, a pasted
    /// address, a clear) is dropped instead of overwriting the live page —
    /// the capture is async and can outlive its page. Compared on the requested
    /// url, not the rendered one, so a redirect (m1k3.app → www…) still lands.
    func setPageContext(_ context: BrowserContext, for requested: URL) {
        guard currentWebURL == requested else { return }
        pageContext = context
    }

    /// The responder's read of `pageContext` — a lock, not the main actor, because
    /// the turn runs off it (the CoolHead snapshot pattern).
    nonisolated static let liveContext = Mutex<BrowserContext?>(nil)

    /// Resolve whatever's in `input` (a typed link or path).
    func openTyped() {
        releaseScopedAccess()
        pageContext = nil
        target = ReviewTargetResolver.resolve(input)
    }

    /// Open a URL the caller already has access to — a chat-link click, a drop, an
    /// open-panel pick, or a tool call. File URLs are trusted to `.file` (and the
    /// security-scoped grant is activated for QuickLook's lazy reads); web URLs are
    /// validated through the resolver. Presents the panel unless told otherwise.
    func open(url: URL, present: Bool = true) {
        releaseScopedAccess()
        let restoredContext = pageContext
        pageContext = nil
        if url.isFileURL {
            // `startAccessingSecurityScopedResource()` returns false for URLs that
            // are ALREADY reachable without scoping (the common case for a file
            // dropped / picked in-session) as well as for genuinely-denied ones —
            // the bool can't tell them apart. So we only RETAIN the grant when it's
            // truly scoped, but always show the file: QuickLook renders it if
            // readable and shows its own "no preview" if not. (Treating false as a
            // hard failure would wrongly reject readable files.)
            if url.startAccessingSecurityScopedResource() {
                scopedURL = url
            }
            input = url.path
            target = .file(url)
        } else {
            input = url.absoluteString
            // forGranted is the safety net: chip-tap and tool callers pre-validate
            // (web-only), but a drag-drop of a non-file URL hasn't been — so we
            // still route it through the resolver here rather than trusting it raw.
            let next = ReviewTarget.forGranted(url)
            // Re-opening the page already showing doesn't reload the keyed web
            // view, so its context stays; only a real change clears it.
            if next == target { pageContext = restoredContext }
            target = next
        }
        if present {
            isPresented = true
        }
    }

    /// Show a code artifact M1K3's brain generated — formats it first, then
    /// presents it in the artifact view (preview + code + export).
    func open(artifact: CodeArtifact, present: Bool = true) {
        releaseScopedAccess()
        pageContext = nil
        let formatted = ArtifactFormatter.format(artifact)
        input = "M1K3 generated · \(formatted.filename)"
        target = .artifact(formatted)
        if present {
            isPresented = true
        }
    }

    /// Reset to the empty resting state.
    func clear() {
        releaseScopedAccess()
        pageContext = nil
        input = ""
        target = .empty
    }

    /// Relinquish any security-scoped file access we're holding. Called on every
    /// transition off a file target (open / clear do).
    ///
    /// No `deinit` belt: under Swift 6 a nonisolated deinit can't touch the
    /// MainActor-isolated `scopedURL`, and the workarounds (`nonisolated(unsafe)` /
    /// `assumeIsolated`) cost more safety than the leak guards against — this model
    /// lives for the app's lifetime, so a never-cleared grant is reclaimed at exit.
    func releaseScopedAccess() {
        if let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
            self.scopedURL = nil
        }
    }
}
