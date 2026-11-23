import Foundation
@testable import M1K3Preview
import Testing
import UniformTypeIdentifiers

struct CodeArtifactTests {
    // MARK: - Language detection

    @Test("language from common file extensions")
    func languageFromExtension() {
        #expect(CodeArtifact.Language(fileExtension: "html") == .html)
        #expect(CodeArtifact.Language(fileExtension: "htm") == .html)
        #expect(CodeArtifact.Language(fileExtension: "css") == .css)
        #expect(CodeArtifact.Language(fileExtension: "js") == .js)
        #expect(CodeArtifact.Language(fileExtension: "HTML") == .html)
    }

    @Test("unknown extension returns nil")
    func unknownExtension() {
        #expect(CodeArtifact.Language(fileExtension: "swift") == nil)
        #expect(CodeArtifact.Language(fileExtension: "") == nil)
    }

    @Test("language inferred from source content")
    func languageFromContent() {
        #expect(CodeArtifact.Language.detect(from: "<html><body>hi</body></html>") == .html)
        #expect(CodeArtifact.Language.detect(from: "<!DOCTYPE html>") == .html)
        #expect(CodeArtifact.Language.detect(from: "<div>hello</div>") == .html)
        #expect(CodeArtifact.Language.detect(from: "body { color: red; }") == .css)
        #expect(CodeArtifact.Language.detect(from: ".container { display: flex; }") == .css)
        #expect(CodeArtifact.Language.detect(from: "function hello() { return 1; }") == .js)
        #expect(CodeArtifact.Language.detect(from: "const x = 42;") == .js)
    }

    // MARK: - Filename

    @Test("default filename uses language extension")
    func defaultFilename() {
        let artifact = CodeArtifact(source: "<p>hi</p>", language: .html)
        #expect(artifact.filename.hasSuffix(".html"))

        let css = CodeArtifact(source: "body {}", language: .css)
        #expect(css.filename.hasSuffix(".css"))

        let js = CodeArtifact(source: "alert(1)", language: .js)
        #expect(js.filename.hasSuffix(".js"))
    }

    @Test("custom title is reflected in filename")
    func customTitleFilename() {
        let artifact = CodeArtifact(source: "<p>hi</p>", language: .html, title: "My Page")
        #expect(artifact.filename == "My Page.html")
    }

    @Test("untitled artifact gets a default filename")
    func untitledFilename() {
        let artifact = CodeArtifact(source: "<p>hi</p>", language: .html)
        #expect(artifact.filename == "generated.html")
    }

    // MARK: - Export

    // MARK: - Display title

    @Test("displayTitle uses language name when no title set")
    func displayTitleDefault() {
        #expect(CodeArtifact(source: "", language: .html).displayTitle == "Generated HTML")
        #expect(CodeArtifact(source: "", language: .css).displayTitle == "Generated CSS")
        #expect(CodeArtifact(source: "", language: .js).displayTitle == "Generated JS")
    }

    @Test("displayTitle uses custom title when set")
    func displayTitleCustom() {
        let artifact = CodeArtifact(source: "", language: .html, title: "My Page")
        #expect(artifact.displayTitle == "My Page")
    }

    // MARK: - UTType

    @Test("utType returns language-appropriate type")
    func languageUTType() {
        #expect(CodeArtifact.Language.html.utType == .html)
        #expect(CodeArtifact.Language.js.utType == .javaScript)
        #expect(CodeArtifact.Language.css.utType == .sourceCode)
    }

    // MARK: - Export

    @Test("exportData returns source encoded as UTF-8")
    func exportData() {
        let source = "<p>hello</p>"
        let artifact = CodeArtifact(source: source, language: .html)
        #expect(artifact.exportData == source.data(using: .utf8))
    }

    // MARK: - Share as a file (Kev, 2026-11-23: "it share's back to my mac as a text file - not HTML")

    @Test("a shared artifact is a file of its own type: an HTML page arrives as .html, not as text")
    func shareFileType() throws {
        #expect(CodeArtifact.Language.html.shareFileType == .html)
        #expect(CodeArtifact.Language.js.shareFileType == .javaScript)
        #expect(try CodeArtifact.Language.css.shareFileType == #require(UTType(filenameExtension: "css")))
        #expect(try CodeArtifact.Language.markdown.shareFileType == #require(UTType(filenameExtension: "md")))
        #expect(CodeArtifact.Language.code.shareFileType == .plainText)
        // Every share type agrees with the extension the file is named with.
        for language in [CodeArtifact.Language.html, .css, .js, .markdown, .code] {
            let named = try #require(UTType(filenameExtension: language.fileExtension), "\(language)")
            #expect(named.conforms(to: language.shareFileType), "\(language): \(named.identifier)")
        }
        #expect(CodeArtifact(source: "<p>hi</p>", language: .html).filename == "generated.html")
    }
}
