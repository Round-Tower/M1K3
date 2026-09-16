import Foundation
@testable import M1K3Inference
import Testing

struct FileAttachmentTests {
    @Test("contextBlock includes the filename and extracted text")
    func contextBlockShape() {
        let file = FileAttachment(filename: "notes.pdf", extractedText: "The quick brown fox.")
        let block = file.contextBlock
        #expect(block.contains("FILE: notes.pdf"))
        #expect(block.contains("The quick brown fox."))
        #expect(block.contains("---"))
    }

    @Test("empty text produces a valid block with just the filename")
    func emptyText() {
        let file = FileAttachment(filename: "blank.txt", extractedText: "")
        #expect(file.contextBlock.contains("FILE: blank.txt"))
    }

    @Test("FileAttachment is Codable round-trip")
    func codableRoundTrip() throws {
        let original = FileAttachment(filename: "doc.pdf", extractedText: "Hello world")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileAttachment.self, from: data)
        #expect(decoded == original)
    }
}
