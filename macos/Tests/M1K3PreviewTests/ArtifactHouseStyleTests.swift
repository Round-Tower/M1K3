//
//  ArtifactHouseStyleTests.swift
//  M1K3PreviewTests
//
//  The house sheet: M1K3's output signature. A CLASSLESS base layer injected
//  first-in-head so any semantic HTML an on-device model emits looks
//  deliberately designed — while the model's OWN styles, arriving later in
//  the head, always cascade over it (the house look is a floor, not a cage).
//

@testable import M1K3Preview
import Testing

struct ArtifactHouseStyleTests {
    @Test("every formatted HTML artifact carries the house sheet")
    func htmlCarriesHouseSheet() {
        let formatted = ArtifactFormatter.formatHTML("<p>hello</p>")
        // Marker-based: normalizeIndentation re-flows whitespace inside the
        // element, so byte-exact containment of styleElement would be brittle.
        #expect(formatted.contains(ArtifactHouseStyle.marker))
        #expect(formatted.contains("--m1k3-accent"))
    }

    @Test("the house sheet precedes the author's own <style> — author always wins the cascade")
    func houseSheetPrecedesAuthorStyles() throws {
        let input = """
        <!DOCTYPE html>
        <html><head><style>body { background: #0a0a0a; }</style></head>
        <body><p>dark by choice</p></body></html>
        """
        let formatted = ArtifactFormatter.formatHTML(input)
        let house = try #require(formatted.range(of: ArtifactHouseStyle.marker))
        let author = try #require(formatted.range(of: "background: #0a0a0a"))
        #expect(house.lowerBound < author.lowerBound)
    }

    @Test("injection is idempotent — formatting twice yields one house sheet")
    func idempotentInjection() {
        let once = ArtifactFormatter.formatHTML("<p>hi</p>")
        let twice = ArtifactFormatter.formatHTML(once)
        let occurrences = twice.components(separatedBy: ArtifactHouseStyle.marker).count - 1
        #expect(occurrences == 1)
    }

    @Test("the markdown preview rides the same sheet — one design language")
    func markdownSharesHouseSheet() {
        let doc = ArtifactFormatter.formatMarkdown("# Hello\n\nSome prose.")
        #expect(doc.contains(ArtifactHouseStyle.marker))
        #expect(doc.contains("--m1k3-accent"))
    }

    @Test("the CSP still seals the document and still permits inline styles")
    func cspSurvivesInjection() {
        let formatted = ArtifactFormatter.formatHTML("<p>hi</p>")
        #expect(formatted.contains(ArtifactSandboxPolicy.contentSecurityPolicy))
        #expect(ArtifactSandboxPolicy.contentSecurityPolicy.contains("style-src 'unsafe-inline'"))
    }

    @Test("the sheet is classless and self-contained — no class selectors, no external loads")
    func sheetIsClasslessAndInert() {
        // Classless: it must style semantic tags, never invent a class system the
        // model can't know about. Self-contained: url() would die at the sandbox
        // wall anyway — the sheet must not depend on any fetch.
        #expect(!ArtifactHouseStyle.css.contains("url("))
        #expect(!ArtifactHouseStyle.css.contains("@import"))
        for line in ArtifactHouseStyle.css.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A leading "." would be a class selector (numbers like ".5em" appear
            // only mid-line in values, never at a rule start).
            #expect(!trimmed.hasPrefix("."), "class selector leaked into the house sheet: \(trimmed)")
        }
    }

    @Test("the entrance never fades from invisible — a suspended animation must leave content readable")
    func entranceIsTransformOnly() {
        // Caught by the render probe (2026-07-16): an opacity-0 from-state plus a
        // compositor that never runs the animation (occluded window, suspended
        // surface) renders a permanently blank page. Motion may only MOVE
        // content, never hide it.
        #expect(!ArtifactHouseStyle.css.contains("opacity: 0"))
    }

    @Test("a headless fragment still gets the house sheet via the synthesized head")
    func fragmentGetsHouseSheet() {
        let formatted = ArtifactFormatter.formatHTML("<h1>Just a heading</h1><p>and prose</p>")
        #expect(formatted.contains(ArtifactHouseStyle.marker))
    }

    @Test("no h1+p subtitle special-case — an ordinary intro paragraph must stay an ordinary paragraph")
    func noSubtitleSpecialCase() {
        // Review catch (#44): "# Title\n\nIntro." renders as literal h1+p
        // adjacent siblings, so an unconditional h1 + p rule would centre and
        // italicise the most common markdown reply's FIRST REAL PARAGRAPH as
        // if it were a subtitle. Cut, not conditioned — classless means no
        // shape-guessing.
        #expect(!ArtifactHouseStyle.css.contains("h1 + p"))
    }

    @Test("a <header> element is not a <head>: the house sheet never lands in body content")
    func headerIsNotHead() {
        // Boundary catch (#44): range(of: "<head") also matches "<header". With no real <head> the house sheet
        // anchors after the CSP, which now always leads the document (so it is never buried in the body).
        let doc = "<!DOCTYPE html>\n<html>\n<body>\n<header>title</header>\n<p>x</p>\n</body>\n</html>"
        #expect(ArtifactFormatter.injectHouseStyle(doc) == doc, "no <head> and no CSP yet: nowhere safe for the sheet")
        let sealed = ArtifactFormatter.injectCSPMeta(doc)
        #expect(sealed.hasPrefix("<!DOCTYPE html>\n" + ArtifactSandboxPolicy.cspMetaTag))
    }

    @Test("a real <head> still receives both injections — including the '<head >' whitespace form")
    func realHeadStillInjects() {
        for open in ["<head>", "<head >", "<HEAD>"] {
            let doc = "<!DOCTYPE html>\n<html>\n\(open)</head>\n<body><p>x</p></body>\n</html>"
            let out = ArtifactFormatter.injectHouseStyle(ArtifactFormatter.injectCSPMeta(doc))
            #expect(out.contains(ArtifactSandboxPolicy.contentSecurityPolicy), "CSP missing for \(open)")
            #expect(out.contains(ArtifactHouseStyle.marker), "house sheet missing for \(open)")
        }
    }
}
