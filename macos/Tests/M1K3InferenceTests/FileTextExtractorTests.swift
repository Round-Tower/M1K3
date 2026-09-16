import Foundation
@testable import M1K3Inference
import Testing

struct FileTextExtractorTests {
    @Test("extracts plain text from a .txt file")
    func plainText() throws {
        let url = try writeTempFile("hello.txt", content: "Hello from a text file.")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attachment = try FileTextExtractor.extract(from: url)
        #expect(attachment.filename == "hello.txt")
        #expect(attachment.extractedText == "Hello from a text file.")
    }

    @Test("extracts Swift source code")
    func swiftSource() throws {
        let url = try writeTempFile("Example.swift", content: "import Foundation\nprint(\"hi\")")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attachment = try FileTextExtractor.extract(from: url)
        #expect(attachment.filename == "Example.swift")
        #expect(attachment.extractedText.contains("import Foundation"))
    }

    @Test("extracts JSON files")
    func jsonFile() throws {
        let url = try writeTempFile("data.json", content: "{\"key\": \"value\"}")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attachment = try FileTextExtractor.extract(from: url)
        #expect(attachment.extractedText.contains("key"))
    }

    @Test("trims whitespace from extracted text")
    func trimming() throws {
        let url = try writeTempFile("padded.txt", content: "\n\n  Hello  \n\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attachment = try FileTextExtractor.extract(from: url)
        #expect(attachment.extractedText == "Hello")
    }

    @Test("empty file throws emptyContent")
    func emptyFile() throws {
        let url = try writeTempFile("empty.txt", content: "   \n\n  ")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: FileTextExtractor.ExtractionError.self) {
            try FileTextExtractor.extract(from: url)
        }
    }

    @Test("unknown extension falls back to UTF-8 text if readable")
    func unknownTextFallback() throws {
        let url = try writeTempFile("notes.myext", content: "Some readable notes.")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attachment = try FileTextExtractor.extract(from: url)
        #expect(attachment.extractedText == "Some readable notes.")
    }

    // MARK: - Helpers

    private func writeTempFile(_ name: String, content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
