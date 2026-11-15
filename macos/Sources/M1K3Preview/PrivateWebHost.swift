//
//  PrivateWebHost.swift
//  M1K3Preview
//
//  The two things every in-app web host shares (#839): a NON-persistent WebKit profile, so a page
//  leaves no cookies, cache or history ("nothing lingers"), and one navigation guard over
//  `WebURLPolicy.refusesNavigation` (#269), so a page cannot carry the host into private space
//  or a local file by itself. The iOS voice-page host is built from exactly these; the Mac's
//  WebReviewView takes its configuration from here and keeps its own coordinator (a follow-up
//  folds it onto the guard). `SFSafariViewController` is out on purpose: it shares Safari's
//  cookies.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.85 (mirrors the Mac coordinator's
//  decision table, which has run since #269; the guard is pinned by PrivateWebHostTests).
//  Prior: none (new file).

#if canImport(WebKit)
    import Foundation
    import WebKit

    public enum PrivateWebConfiguration {
        /// A configuration whose data store is non-persistent and private to the web view made from it.
        @MainActor
        public static func make() -> WKWebViewConfiguration {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            return configuration
        }
    }

    /// Judges each main-frame move of one host's web view. The first load is the host's own (the open
    /// policy already vetted it); after that, `WebURLPolicy.refusesNavigation` decides.
    @MainActor
    public final class WebNavigationGuard {
        private let resolver: any HostResolving
        private let initialURL: URL
        private var startedPrivate: Task<Bool, Never>?

        public init(initialURL: URL, resolver: any HostResolving = SystemHostResolver()) {
            self.initialURL = initialURL
            self.resolver = resolver
        }

        /// Whether the move to `target` may go ahead. Only http(s) and file targets are judged.
        public func allows(_ target: URL, isMainFrame: Bool, userInitiated: Bool) async -> Bool {
            guard isMainFrame, ["http", "https", "file"].contains(target.scheme?.lowercased() ?? "") else { return true }
            guard let startedPrivate else {
                let start = initialURL
                let resolver = resolver
                startedPrivate = Task { await WebURLPolicy.startsPrivate(start, resolver: resolver) }
                return true
            }
            let refused = await WebURLPolicy.refusesNavigation(
                startedPrivate: startedPrivate.value, to: target, userInitiated: userInitiated, resolver: resolver
            )
            return !refused
        }
    }
#endif
