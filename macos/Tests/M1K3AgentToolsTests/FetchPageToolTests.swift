//
//  FetchPageToolTests.swift
//  M1K3AgentToolsTests
//
//  web_search finds pages; fetch_page READS one — the difference between a
//  link list and an actual answer. Pure extractor pinned on synthetic HTML;
//  tool orchestration pinned with the scripted fetcher (scheme guard, browser
//  headers, output cap, errors as observations).
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.85, Prior: Unknown

import Foundation
@testable import M1K3AgentTools
import Synchronization
import Testing

struct HTMLTextExtractorTests {
    @Test("extracts readable text, dropping head/script/style and tags")
    func extractsReadableText() {
        let html = """
        <html><head><title>Boston Weather</title><style>.x{color:red}</style></head>
        <body>
        <script>var tracking = "junk";</script>
        <nav><a href="/">Home</a></nav>
        <h1>10-Day Forecast</h1>
        <p>Tuesday: Sunny, high of <b>25&#176;</b>. Wednesday: showers &amp; wind.</p>
        <!-- a comment -->
        </body></html>
        """
        let text = HTMLTextExtractor.text(from: html)
        #expect(text.contains("10-Day Forecast"))
        #expect(text.contains("Tuesday: Sunny, high of 25°. Wednesday: showers & wind."))
        #expect(!text.contains("tracking"))
        #expect(!text.contains("color:red"))
        #expect(!text.contains("<"))
        #expect(!text.contains("a comment"))
        // Chrome (nav/header/footer) is dropped wholesale — on real pages it
        // eats the output cap before the content starts (seen live).
        #expect(!text.contains("Home"))
    }

    @Test("block elements become line breaks, runs of blank lines collapse")
    func blockStructure() {
        let html = "<body><p>one</p><p>two</p><div>three</div></body>"
        #expect(HTMLTextExtractor.text(from: html) == "one\ntwo\nthree")
    }

    @Test("garbage in, empty out — never a crash")
    func garbage() {
        #expect(HTMLTextExtractor.text(from: "").isEmpty)
        #expect(HTMLTextExtractor.text(from: "<script>only junk</script>").isEmpty)
    }
}

struct FetchPageToolTests {
    private final class ScriptedFetcher: HTTPFetching, Sendable {
        private let requestLog = Mutex<[URLRequest]>([])
        private let body: String

        init(body: String) {
            self.body = body
        }

        var requests: [URLRequest] {
            requestLog.withLock { $0 }
        }

        func fetch(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
            requestLog.withLock { $0.append(request) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }

    @Test("fetches a page with browser headers and returns its readable text")
    func fetchesReadableText() async throws {
        let fetcher = ScriptedFetcher(body: "<body><h1>Forecast</h1><p>Sunny, 25.</p></body>")
        let tool = FetchPageTool(fetcher: fetcher)
        let result = try await tool.execute(input: ["url": "https://weather.example/boston"])
        #expect(result.output.contains("Forecast"))
        #expect(result.output.contains("Sunny, 25."))
        let request = try #require(fetcher.requests.first)
        #expect(request.url?.absoluteString == "https://weather.example/boston")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
    }

    @Test("only http(s) urls are fetched")
    func schemeGuard() async throws {
        let fetcher = ScriptedFetcher(body: "nope")
        let tool = FetchPageTool(fetcher: fetcher)
        let file = try await tool.execute(input: ["url": "file:///etc/passwd"])
        #expect(file.output.hasPrefix("Error:"))
        let junk = try await tool.execute(input: ["url": "not a url"])
        #expect(junk.output.hasPrefix("Error:"))
        let empty = try await tool.execute(input: ["url": "  "])
        #expect(empty.output.hasPrefix("Error:"))
        #expect(fetcher.requests.isEmpty)
    }

    @Test("a read leads with the page's own title and description, then the text")
    func titledRead() async throws {
        let fetcher = ScriptedFetcher(body: """
        <html><head><title>M1K3 for Mac — Nothing leaves.</title>
        <meta name="description" content="A fully on-device AI companion for macOS."></head>
        <body><p>0 bytes of your data sent to a server.</p></body></html>
        """)
        let tool = FetchPageTool(fetcher: fetcher)
        let result = try await tool.execute(input: ["url": "https://m1k3.app"])
        #expect(result.output.hasPrefix("Page: M1K3 for Mac — Nothing leaves."))
        #expect(result.output.contains("A fully on-device AI companion for macOS."))
        #expect(result.output.contains("0 bytes of your data sent to a server."))
        // The header comes before the text, so a model reads the frame first.
        let title = try #require(result.output.range(of: "Nothing leaves.")?.lowerBound)
        let body = try #require(result.output.range(of: "0 bytes")?.lowerBound)
        #expect(title < body)
    }

    @Test("an untitled page is still framed — by its host")
    func untitledReadNamesTheHost() async throws {
        let fetcher = ScriptedFetcher(body: "<body><p>Plain words.</p></body>")
        let tool = FetchPageTool(fetcher: fetcher)
        let result = try await tool.execute(input: ["url": "https://example.org/notes"])
        #expect(result.output.hasPrefix("Page: example.org"))
        #expect(result.output.contains("Plain words."))
    }

    @Test("the header counts against the cap — a long page still stays within it")
    func headerIsInsideTheCap() async throws {
        let long = String(repeating: "word ", count: 2000)
        let fetcher = ScriptedFetcher(body: "<html><head><title>Long</title></head><body><p>\(long)</p></body></html>")
        let tool = FetchPageTool(fetcher: fetcher, maxCharacters: 300)
        let result = try await tool.execute(input: ["url": "https://example.org"])
        #expect(result.output.hasPrefix("Page: Long"))
        #expect(result.output.count <= 301)
        #expect(result.output.hasSuffix("…"))
    }

    @Test("a bare domain — what the routing rule tells the model to pass — is read over https")
    func bareDomainIsCoerced() async throws {
        let fetcher = ScriptedFetcher(body: "<html><body><p>M1K3 for Mac. Nothing leaves.</p></body></html>")
        let tool = FetchPageTool(fetcher: fetcher)
        let result = try await tool.execute(input: ["url": "m1k3.app"])
        #expect(!result.output.hasPrefix("Error:"))
        #expect(result.output.contains("Nothing leaves"))
        #expect(fetcher.requests.first?.url?.absoluteString == "https://m1k3.app")
        // With a path too — the resolver's rule, mirrored.
        let deep = try await tool.execute(input: ["url": "m1k3.app/blog/hello"])
        #expect(!deep.output.hasPrefix("Error:"))
        #expect(fetcher.requests.last?.url?.absoluteString == "https://m1k3.app/blog/hello")
    }

    @Test("the unusable-address error never points the model back at web_search")
    func errorDoesNotRouteToSearch() async throws {
        let fetcher = ScriptedFetcher(body: "nope")
        let tool = FetchPageTool(fetcher: fetcher)
        let junk = try await tool.execute(input: ["url": "not a url"])
        #expect(junk.output.hasPrefix("Error:"))
        #expect(!junk.output.contains("web_search"))
        #expect(fetcher.requests.isEmpty)
    }

    @Test("SSRF: loopback / private / obfuscated-local targets are refused, never fetched")
    func refusesLocalTargets() async throws {
        let fetcher = ScriptedFetcher(body: "secret internal content")
        let tool = FetchPageTool(fetcher: fetcher)
        for target in [
            "http://127.0.0.1:5000/admin",
            "http://169.254.169.254/latest/meta-data/",
            "http://0177.0.0.1/",
            "http://2130706433/",
            "http://[::1]/",
            "http://192.168.1.1/",
        ] {
            let result = try await tool.execute(input: ["url": target])
            #expect(result.output.hasPrefix("Error:"), "expected refusal for \(target)")
        }
        #expect(fetcher.requests.isEmpty)
    }

    @Test("long pages are capped so a small model's context survives")
    func capsOutput() async throws {
        let longBody = "<body><p>" + String(repeating: "forecast words ", count: 500) + "</p></body>"
        let fetcher = ScriptedFetcher(body: longBody)
        let tool = FetchPageTool(fetcher: fetcher)
        let result = try await tool.execute(input: ["url": "https://a.example"])
        #expect(result.output.count <= 1600)
        #expect(result.output.hasSuffix("…"))
    }

    @Test("a page with no readable text is reported honestly")
    func emptyPage() async throws {
        let fetcher = ScriptedFetcher(body: "<script>spa(){}</script>")
        let tool = FetchPageTool(fetcher: fetcher)
        let result = try await tool.execute(input: ["url": "https://spa.example"])
        #expect(result.output.contains("no readable text"))
    }

    @Test("network failure becomes a recoverable Error observation")
    func networkFailure() async throws {
        struct Boom: Error {}
        final class ThrowingFetcher: HTTPFetching, Sendable {
            func fetch(_: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
                throw Boom()
            }
        }
        let tool = FetchPageTool(fetcher: ThrowingFetcher())
        let result = try await tool.execute(input: ["url": "https://a.example"])
        #expect(result.output.hasPrefix("Error: could not fetch"))
    }

    @Test("declares the agent-facing contract")
    func declaresContract() {
        let tool = FetchPageTool()
        #expect(tool.name == "fetch_page")
        #expect(tool.description.contains("web_search"))
        #expect(tool.parameters.first?.name == "url")
    }
}
