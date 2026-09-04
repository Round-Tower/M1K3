//
//  OpenLinkToolTests.swift
//  M1K3AgentToolsTests
//
//  Signed: Kev + claude-opus-4-8, 2026-06-19, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-04 — the tool now READS what it opens
//  (PageBrief) so the model stops describing pages it never saw; every test
//  injects a scripted fetcher (no live network in the suite), and three new
//  tests pin the brief, the read-failure wording, and open-before-read.

import Foundation
@testable import M1K3AgentTools
import Testing

/// Serves scripted bodies by path; anything else is a host that can't be found.
private final class RoutedFetcher: HTTPFetching, Sendable {
    private let routes: [String: (status: Int, body: String)]

    init(_ routes: [String: (status: Int, body: String)] = [:]) {
        self.routes = routes
    }

    func fetch(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let url = request.url!
        let path = url.path.isEmpty ? "/" : url.path
        guard let hit = routes[path] else { throw URLError(.cannotFindHost) }
        let response = HTTPURLResponse(
            url: url, statusCode: hit.status, httpVersion: nil,
            headerFields: ["Content-Type": path.hasSuffix(".txt") ? "text/plain" : "text/html; charset=utf-8"]
        )!
        return (Data(hit.body.utf8), response)
    }
}

private let offline = RoutedFetcher()

/// Records when each fetch starts and ends, and holds each one open long enough
/// that sequential calls can't overlap by accident.
private final class TimingFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [String: Date] = [:]
    private var ends: [String: Date] = [:]

    func fetch(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let path = request.url!.path
        lock.withLock { starts[path] = Date() }
        try await Task.sleep(for: .milliseconds(150))
        lock.withLock { ends[path] = Date() }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("<html><head><title>T</title></head><body>b</body></html>".utf8), response)
    }

    func window(_ path: String) -> (start: Date, end: Date)? {
        lock.withLock {
            guard let s = starts[path], let e = ends[path] else { return nil }
            return (s, e)
        }
    }
}

struct OpenLinkToolTests {
    /// A thread-safe sink for the URL the tool hands back, so we can assert what
    /// would be opened without any UI.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _url: URL?
        var url: URL? {
            lock.lock(); defer { lock.unlock() }
            return _url
        }

        func set(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            _url = url
        }
    }

    @Test("a valid https URL is opened and confirmed")
    func opensHTTPS() async throws {
        let box = Box()
        let tool = OpenLinkTool(fetcher: offline) { box.set($0) }
        let result = try await tool.execute(input: ["url": "https://example.com/page"])
        #expect(box.url == URL(string: "https://example.com/page"))
        #expect(!result.output.hasPrefix("Error:"))
    }

    @Test("a bare domain is coerced to https and opened")
    func coercesBareDomain() async throws {
        let box = Box()
        let tool = OpenLinkTool(fetcher: offline) { box.set($0) }
        _ = try await tool.execute(input: ["url": "example.com"])
        #expect(box.url == URL(string: "https://example.com"))
    }

    @Test("an empty argument is a recoverable error, nothing opened")
    func emptyIsError() async throws {
        let box = Box()
        let tool = OpenLinkTool(fetcher: offline) { box.set($0) }
        let result = try await tool.execute(input: [:])
        #expect(result.output.hasPrefix("Error:"))
        #expect(box.url == nil)
    }

    @Test("a non-web target (a file path) is refused — the tool opens links, not files")
    func refusesNonWeb() async throws {
        let box = Box()
        let tool = OpenLinkTool(fetcher: offline) { box.set($0) }
        let result = try await tool.execute(input: ["url": "/etc/hosts"])
        #expect(result.output.hasPrefix("Error:"))
        #expect(box.url == nil)
    }

    @Test("a local/private-network address is refused — no SSRF via the panel")
    func refusesLocalNetwork() async throws {
        let box = Box()
        let tool = OpenLinkTool(fetcher: offline) { box.set($0) }
        for raw in ["http://localhost:3000", "http://127.0.0.1", "http://192.168.1.1", "http://169.254.169.254"] {
            let result = try await tool.execute(input: ["url": raw])
            #expect(result.output.hasPrefix("Error:"))
        }
        #expect(box.url == nil)
    }

    @Test("declares the open_link contract the model sees — show AND brief, fetch_page to read")
    func contract() {
        let tool = OpenLinkTool(fetcher: offline) { _ in }
        #expect(tool.name == "open_link")
        #expect(tool.parameters.first?.name == "url")
        #expect(tool.description.contains("fetch_page"))
    }

    @Test("the brief carries the page's title, the site's llms.txt note, and its text")
    func briefFromPage() async throws {
        let box = Box()
        let fetcher = RoutedFetcher([
            "/": (200, "<html><head><title>Example Site</title></head><body><p>Hello from the example.</p></body></html>"),
            "/llms.txt": (200, "# Example\n> The example site, for agents."),
        ])
        let tool = OpenLinkTool(fetcher: fetcher) { box.set($0) }
        let result = try await tool.execute(input: ["url": "https://example.com/"])
        #expect(box.url == URL(string: "https://example.com/"))
        #expect(result.output.contains("Opened example.com in the review panel."))
        #expect(result.output.contains("Title: Example Site"))
        #expect(result.output.contains("(llms.txt): # Example > The example site, for agents."))
        #expect(result.output.contains("Page text: Hello from the example."))
    }

    @Test("a missing llms.txt is simply absent from the brief")
    func noLLMSText() async throws {
        let fetcher = RoutedFetcher([
            "/": (200, "<html><head><title>Plain</title></head><body><p>Just a page.</p></body></html>"),
        ])
        let tool = OpenLinkTool(fetcher: fetcher) { _ in }
        let result = try await tool.execute(input: ["url": "https://example.com/"])
        #expect(result.output.contains("Title: Plain"))
        #expect(!result.output.contains("llms.txt"))
    }

    @Test("the page and llms.txt are fetched concurrently — the model never waits for two timeouts")
    func fetchesConcurrently() async throws {
        let fetcher = TimingFetcher()
        let tool = OpenLinkTool(fetcher: fetcher) { _ in }
        _ = try await tool.execute(input: ["url": "https://example.com/docs"])
        let page = try #require(fetcher.window("/docs"))
        let llms = try #require(fetcher.window("/llms.txt"))
        // The second request began before the first one finished.
        #expect(llms.start < page.end)
        #expect(page.start < llms.end)
    }

    @Test("the panel opens even when the read fails — and the brief says so, in words the model can't misread")
    func opensBeforeRead() async throws {
        let box = Box()
        let tool = OpenLinkTool(fetcher: offline) { box.set($0) }
        let result = try await tool.execute(input: ["url": "https://example.com/"])
        #expect(box.url == URL(string: "https://example.com/"))
        #expect(result.output.contains("could not read its content"))
        #expect(result.output.contains("Do not describe the page"))
        #expect(!result.output.contains("Page text:"))
    }
}
