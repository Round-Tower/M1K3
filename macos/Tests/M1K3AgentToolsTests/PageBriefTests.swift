import Foundation
@testable import M1K3AgentTools
import Testing

/// open_link used to hand the model one line — "Opened m1k3.app in the review
/// panel." — and nothing about the page. Given nothing, Lil described a page it
/// had never read ("a static page … coming soon"; Kev's dislike, 2026-09-04).
/// The brief is what the model gets instead: title, description, the site's own
/// note for AI agents (llms.txt), a first chunk of readable text — or an
/// explicit "could not read it, do not describe it".
struct PageBriefTests {
    private let url = URL(string: "https://m1k3.app/")!
    private let html = """
    <html><head><title>M1K3 — a local AI that lives on your Mac</title>
    <meta name="description" content="Private, on-device AI for macOS: MLX inference, live voice, memory.">
    </head><body><nav>Home</nav><h1>Meet M1K3</h1><p>Everything stays on your machine.</p></body></html>
    """

    @Test("title and meta description come out of the head the text extractor drops")
    func titleAndDescription() {
        #expect(PageBrief.title(from: html) == "M1K3 — a local AI that lives on your Mac")
        #expect(
            PageBrief.metaDescription(from: html)
                == "Private, on-device AI for macOS: MLX inference, live voice, memory."
        )
        #expect(PageBrief.title(from: "<body>no head</body>") == nil)
        // content before name, single quotes, entities — the wild shapes
        #expect(
            PageBrief.metaDescription(from: "<meta content='Tom &amp; Jerry' name='description'>")
                == "Tom & Jerry"
        )
    }

    @Test("a readable page renders title, description, the site's llms.txt note, and page text")
    func fullBrief() {
        let brief = PageBrief.render(
            url: url,
            sources: .init(html: html, llmsText: "# M1K3\n> On-device AI for macOS.\nBuilt by Round Tower.")
        )
        #expect(brief.hasPrefix("Opened m1k3.app in the review panel."))
        #expect(brief.contains("Title: M1K3 — a local AI that lives on your Mac"))
        #expect(brief.contains("Description: Private, on-device AI for macOS"))
        #expect(
            brief.contains(
                "The site's own note for AI agents (llms.txt): # M1K3 > On-device AI for macOS. Built by Round Tower."
            )
        )
        #expect(brief.contains("Page text: Meet M1K3\nEverything stays on your machine."))
        #expect(!brief.contains("Home")) // chrome dropped — same extractor as fetch_page
        #expect(!brief.contains("Do not describe"))
    }

    @Test("llms.txt and page text are capped with an ellipsis, so one page can't eat the turn")
    func caps() throws {
        let long = String(repeating: "word ", count: 2000)
        let brief = PageBrief.render(
            url: url, sources: .init(html: "<body><p>\(long)</p></body>", llmsText: long),
            textBudget: 100, llmsBudget: 50
        )
        let llmsLine = brief.split(separator: "\n").first { $0.hasPrefix("The site's own note") }
        #expect(llmsLine != nil)
        #expect((llmsLine?.count ?? 999) <= "The site's own note for AI agents (llms.txt): ".count + 51)
        #expect(llmsLine?.hasSuffix("…") == true)
        let textStart = try #require(brief.range(of: "Page text: ")?.upperBound)
        #expect(brief[textStart...].count <= 101)
        #expect(brief.hasSuffix("…"))
    }

    @Test("a page that couldn't be read says so and tells the model not to describe it")
    func unreadable() {
        let brief = PageBrief.render(url: url, sources: .init(failure: "HTTP 403"))
        #expect(brief.contains("could not read its content (HTTP 403)"))
        #expect(brief.contains("Do not describe the page"))
        #expect(!brief.contains("Page text:"))
    }

    @Test("a page with no readable text (JavaScript-only) is unreadable, not empty")
    func jsOnly() {
        let brief = PageBrief.render(
            url: url,
            sources: .init(html: "<html><head><title>App</title></head><body><script>boot()</script></body></html>")
        )
        #expect(brief.contains("Title: App"))
        #expect(brief.contains("no readable text"))
        #expect(brief.contains("Do not describe the page"))
        #expect(!brief.contains("Page text:"))
    }

    @Test("an llms.txt that is really the site's HTML shell (SPA fallback) is ignored")
    func llmsHTMLFallbackIgnored() {
        #expect(PageBrief.usableLLMSText("<!doctype html><html><head></head><body>app</body></html>") == nil)
        #expect(PageBrief.usableLLMSText("   \n ") == nil)
        #expect(PageBrief.usableLLMSText("# Site\n> summary") == "# Site\n> summary")
    }

    @Test("llms.txt lives at the site origin, never under the page path")
    func llmsURL() throws {
        #expect(
            try PageBrief.llmsURL(for: #require(URL(string: "https://m1k3.app/docs/voice?x=1")))
                == URL(string: "https://m1k3.app/llms.txt")
        )
        #expect(
            try PageBrief.llmsURL(for: #require(URL(string: "http://example.com:8080/a")))
                == URL(string: "http://example.com:8080/llms.txt")
        )
    }
}
