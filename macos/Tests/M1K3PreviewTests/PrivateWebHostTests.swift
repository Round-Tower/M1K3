//
//  PrivateWebHostTests.swift
//  M1K3PreviewTests
//
//  What every web host in the app shares (#839): a non-persistent WebKit profile (nothing lingers)
//  and one navigation guard that wraps `WebURLPolicy.refusesNavigation`. The iOS host is built from
//  exactly these two; its source is scanned in M1K3AvatarTests (IOSPageHostScanTests).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.85. Prior: none (new file).

import Foundation
@testable import M1K3Preview
import Testing
import WebKit

struct PrivateWebHostTests {
    @Test("the configuration's data store is non-persistent: no cookies, cache or history survive")
    @MainActor
    func nonPersistent() {
        let configuration = PrivateWebConfiguration.make()
        #expect(configuration.websiteDataStore.isPersistent == false)
    }

    @Test("each call gets its own store, so two pages never share cookies")
    @MainActor
    func freshStore() {
        let first = PrivateWebConfiguration.make()
        let second = PrivateWebConfiguration.make()
        #expect(first.websiteDataStore !== second.websiteDataStore)
    }

    private struct Table: HostResolving {
        let answers: [String: [String]]
        func addresses(for host: String) async -> [String]? {
            answers[host] ?? ["93.184.216.34"]
        }
    }

    private func url(_ raw: String) -> URL {
        URL(string: raw) ?? URL(fileURLWithPath: "/")
    }

    @Test("the first main-frame load passes: the host's own, already gated by the open policy")
    @MainActor
    func firstLoadPasses() async {
        let guardian = WebNavigationGuard(initialURL: url("https://example.com"), resolver: Table(answers: [:]))
        #expect(await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false))
    }

    @Test("a page's own redirect into private space is refused, and so is a click the page may have faked")
    @MainActor
    func redirectIntoPrivateRefused() async {
        let guardian = WebNavigationGuard(initialURL: url("https://example.com"), resolver: Table(answers: [:]))
        _ = await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false)
        #expect(await !guardian.allows(url("http://192.168.1.1/admin"), isMainFrame: true, userInitiated: false))
        #expect(await !guardian.allows(url("http://localhost:8080"), isMainFrame: true, userInitiated: false))
        #expect(await guardian.allows(url("https://example.org/next"), isMainFrame: true, userInitiated: false))
        // WebKit gives no user-gesture bit, so a hostile page's scripted click reads as a click. The strict
        // (voice page) guard judges it like any other move, toward private and loopback targets alike.
        #expect(await !guardian.allows(url("http://192.168.1.1/mine"), isMainFrame: true, userInitiated: true))
        #expect(await !guardian.allows(url("http://localhost:4242/mcp"), isMainFrame: true, userInitiated: true))
        #expect(await !guardian.allows(url("http://[::1]:4242/"), isMainFrame: true, userInitiated: true))
        #expect(await guardian.allows(url("https://example.org/clicked"), isMainFrame: true, userInitiated: true))
    }

    @Test("the lenient guard (a person's own panel) still lets a real click go anywhere")
    @MainActor
    func lenientTrustsClicks() async {
        let guardian = WebNavigationGuard(
            initialURL: url("https://example.com"), resolver: Table(answers: [:]), isStrict: false
        )
        _ = await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false)
        #expect(await guardian.allows(url("http://192.168.1.1/mine"), isMainFrame: true, userInitiated: true))
        #expect(await !guardian.allows(url("http://192.168.1.1/admin"), isMainFrame: true, userInitiated: false))
    }

    @Test("strict: only http, https and about pass on the main frame; everything else is cancelled", arguments: [
        "tel:+15551234567", "zoommtg://zoom.us/join?confno=1", "itms-apps://apps.apple.com/app/id1",
        "mailto:a@b.c", "facetime://x", "sms:555", "m1k3://event/x", "data:text/html,hi", "blob:https://example.com/abc",
        "javascript:alert(1)", "ftp://example.com/x", "x-apple.systempreferences:", "file:///etc/hosts",
    ])
    @MainActor
    func strictSchemes(raw: String) async {
        let guardian = WebNavigationGuard(initialURL: url("https://example.com"), resolver: Table(answers: [:]))
        _ = await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false)
        #expect(await !guardian.allows(url(raw), isMainFrame: true, userInitiated: true))
        #expect(await !guardian.allows(url(raw), isMainFrame: true, userInitiated: false))
    }

    @Test("strict: http, https and about main-frame moves pass the scheme check", arguments: [
        "https://example.org/", "http://example.org/", "about:blank", "HTTPS://example.org/",
    ])
    @MainActor
    func strictAllowedSchemes(raw: String) async {
        let guardian = WebNavigationGuard(initialURL: url("https://example.com"), resolver: Table(answers: [:]))
        _ = await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false)
        #expect(await guardian.allows(url(raw), isMainFrame: true, userInitiated: false))
    }

    @Test("strict: a subframe may load blob and data subresources, but still not tel or zoom")
    @MainActor
    func strictSubframes() async {
        let guardian = WebNavigationGuard(initialURL: url("https://example.com"), resolver: Table(answers: [:]))
        _ = await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false)
        #expect(await guardian.allows(url("blob:https://example.com/abc"), isMainFrame: false, userInitiated: false))
        #expect(await guardian.allows(url("data:image/png;base64,AAAA"), isMainFrame: false, userInitiated: false))
        #expect(await !guardian.allows(url("tel:555"), isMainFrame: false, userInitiated: false))
        #expect(await !guardian.allows(url("zoommtg://x"), isMainFrame: false, userInitiated: false))
    }

    @Test("a public name that rebinds into private space is refused on a later move")
    @MainActor
    func rebindRefused() async {
        let resolver = Table(answers: ["rebind.example.com": ["10.0.0.9"]])
        let guardian = WebNavigationGuard(initialURL: url("https://example.com"), resolver: resolver)
        _ = await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false)
        #expect(await !guardian.allows(url("https://rebind.example.com"), isMainFrame: true, userInitiated: false))
    }

    @Test("a local file is refused however the move was made")
    @MainActor
    func fileRefused() async {
        let guardian = WebNavigationGuard(initialURL: url("https://example.com"), resolver: Table(answers: [:]))
        _ = await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false)
        #expect(await !guardian.allows(url("file:///etc/hosts"), isMainFrame: true, userInitiated: true))
        #expect(await !guardian.allows(url("file:///etc/hosts"), isMainFrame: true, userInitiated: false))
    }

    @Test("subframes are left to WebKit")
    @MainActor
    func subframesPass() async {
        let guardian = WebNavigationGuard(initialURL: url("https://example.com"), resolver: Table(answers: [:]))
        _ = await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false)
        #expect(await guardian.allows(url("http://192.168.1.1/ad"), isMainFrame: false, userInitiated: false))
    }

    @Test("a page that started private stays the person's choice: its own moves are not gated")
    @MainActor
    func startedPrivate() async {
        let guardian = WebNavigationGuard(initialURL: url("http://192.168.1.5"), resolver: Table(answers: [:]))
        _ = await guardian.allows(url("http://192.168.1.5"), isMainFrame: true, userInitiated: false)
        #expect(await guardian.allows(url("http://192.168.1.6/x"), isMainFrame: true, userInitiated: false))
        #expect(await !guardian.allows(url("file:///etc/hosts"), isMainFrame: true, userInitiated: false))
    }

    @Test("about:blank passes")
    @MainActor
    func otherSchemesPass() async {
        let guardian = WebNavigationGuard(initialURL: url("https://example.com"), resolver: Table(answers: [:]))
        _ = await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false)
        #expect(await guardian.allows(url("about:blank"), isMainFrame: true, userInitiated: false))
    }
}
