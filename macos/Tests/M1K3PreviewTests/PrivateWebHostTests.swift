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

    @Test("a page's own redirect into private space is refused, a person's click is not")
    @MainActor
    func redirectIntoPrivateRefused() async {
        let guardian = WebNavigationGuard(initialURL: url("https://example.com"), resolver: Table(answers: [:]))
        _ = await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false)
        #expect(await !guardian.allows(url("http://192.168.1.1/admin"), isMainFrame: true, userInitiated: false))
        #expect(await !guardian.allows(url("http://localhost:8080"), isMainFrame: true, userInitiated: false))
        #expect(await guardian.allows(url("https://example.org/next"), isMainFrame: true, userInitiated: false))
        #expect(await guardian.allows(url("http://192.168.1.1/mine"), isMainFrame: true, userInitiated: true))
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

    @Test("non-web schemes are not the guard's to judge")
    @MainActor
    func otherSchemesPass() async {
        let guardian = WebNavigationGuard(initialURL: url("https://example.com"), resolver: Table(answers: [:]))
        _ = await guardian.allows(url("https://example.com"), isMainFrame: true, userInitiated: false)
        #expect(await guardian.allows(url("about:blank"), isMainFrame: true, userInitiated: false))
    }
}
