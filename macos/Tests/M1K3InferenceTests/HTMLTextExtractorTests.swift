//
//  HTMLTextExtractorTests.swift
//  M1K3InferenceTests
//
//  Moved verbatim from M1K3AgentToolsTests/FetchPageToolTests.swift with the extractor (2026-11-14).
//

import Foundation
@testable import M1K3Inference
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

    /// 2026-10-27 web sample: Wikipedia's data-mw attribute is JSON in single quotes that escapes `<` but
    /// not `>`, so `<[^>]+>` ended the tag at `-->` and the rest of the JSON became the page's text.
    @Test("a quoted attribute value holding > stays inside its tag")
    func quotedAngleInAttribute() {
        let html = """
        <body><span data-mw='{"parts":[{"wt":"[[Gov]]&lt;!-- big-g -->&lt;br />[[PCO]]"}]}'></span>
        <p>The prime minister is the head of government.</p>
        <p><a title="a > b" href="/x">Mark Carney</a></p></body>
        """
        #expect(HTMLTextExtractor.text(from: html) == "The prime minister is the head of government.\nMark Carney")
    }

    @Test("a < in the text that opens no tag is kept")
    func strayAngleKept() {
        #expect(HTMLTextExtractor.text(from: "<p>3 < 4 and 5 > 2</p>") == "3 < 4 and 5 > 2")
    }

    /// Pre-push review: a quoted value could match as one run or as `=`, `"`, `"`, so an unclosed tag at the end
    /// of a page made the engine try every split: 22 attributes took 1.3 s, 40 would take days. The regex call
    /// can't be cancelled, so it runs on its own thread and the 30 s wait is a hang guard, not a speed pin (the
    /// parse takes about a millisecond).
    @Test("an unclosed tag full of quoted attributes at the end of a page returns")
    func unclosedTagReturns() {
        final class Result: @unchecked Sendable {
            let lock = NSLock()
            var text: String?
        }
        let html = "<p>Kept.</p><a" + String(repeating: " x=\"\"", count: 40)
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let text = HTMLTextExtractor.text(from: html)
            result.lock.withLock { result.text = text }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 30) == .success)
        #expect(result.lock.withLock { result.text }?.hasPrefix("Kept.") == true)
    }

    @Test("a tag holding a quarter-megabyte unquoted value is still one tag")
    func hugeUnquotedValue() {
        let base64 = String(repeating: "QUJD", count: 75000)
        let html = "<p>Before.</p><img src=data:image/png;base64,\(base64)><p>After.</p>"
        #expect(HTMLTextExtractor.text(from: html) == "Before.\nAfter.")
    }

    @Test("dropped pairs still drop whole, in any case, and a word opener never eats a longer tag")
    func droppedPairsKeepTheirMeaning() {
        let html = "<HEAD><title>T</title></HEAD><header>Menu</header><p>One.</p><SCRIPT>x()</script>"
            + "<!-- note --><p>Two.</p><scripts>Kept tag text</scripts><style>.a{}</style><p>Three.</p>"
        #expect(HTMLTextExtractor.text(from: html) == "One.\nTwo.\nKept tag text Three.")
        #expect(HTMLTextExtractor.text(from: "<p>Open.</p><script>never closed") == "Open.\nnever closed")
    }

    @Test("a < inside a tag ends it, so malformed markup keeps its text instead of swallowing the next tag")
    func angleInsideTagEndsIt() {
        #expect(HTMLTextExtractor.text(from: "<p><a href=x<b>bold</b></p>") == "<a href=xbold")
    }

    @Test("a quote left open after = ends at the next tag, not the next quote")
    func openQuoteStopsAtNextTag() {
        let html = "<p><a href=\"foo>bar</a></p><p>Next \"quoted\" text.</p>"
        #expect(HTMLTextExtractor.text(from: html) == "bar\nNext \"quoted\" text.")
    }

    @Test("garbage in, empty out — never a crash")
    func garbage() {
        #expect(HTMLTextExtractor.text(from: "").isEmpty)
        #expect(HTMLTextExtractor.text(from: "<script>only junk</script>").isEmpty)
    }
}
