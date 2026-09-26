import Foundation
@testable import M1K3Inference
import Testing
import UniformTypeIdentifiers

struct AttachmentRoutingTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/picked/\(name)")
    }

    @Test("an image goes to the vision path, text to the file-as-context path")
    func splitsByKind() {
        let route = AttachmentRouting.route(
            [url("cat.png"), url("notes.md"), url("photo.HEIC"), url("main.swift")],
            imagesAccepted: true
        )
        #expect(route.images.map(\.lastPathComponent) == ["cat.png", "photo.HEIC"])
        #expect(route.files.map(\.lastPathComponent) == ["notes.md", "main.swift"])
        #expect(route.refusedImages.isEmpty)
    }

    @Test("a brain that can't see refuses images instead of reading them as text")
    func refusesImagesWhenBlind() {
        let route = AttachmentRouting.route([url("cat.jpg"), url("todo.txt")], imagesAccepted: false)
        #expect(route.images.isEmpty)
        #expect(route.files.map(\.lastPathComponent) == ["todo.txt"])
        #expect(route.refusedImages.map(\.lastPathComponent) == ["cat.jpg"])
    }

    @Test("an unknown extension is a file: the extractor decides if it reads as text")
    func unknownIsFile() {
        let route = AttachmentRouting.route([url("Makefile"), url("data.weird")], imagesAccepted: true)
        #expect(route.files.count == 2)
        #expect(route.images.isEmpty)
    }

    @Test("the one picker offers images only when the brain can see them")
    func pickerTypes() {
        let seeing = AttachmentRouting.contentTypes(imagesAccepted: true)
        let blind = AttachmentRouting.contentTypes(imagesAccepted: false)
        #expect(seeing.contains(.image))
        #expect(!blind.contains(.image))
        // Everything the file path took before the merge is still offered.
        for type in [UTType.plainText, .text, .sourceCode, .json, .yaml, .xml, .html] {
            #expect(seeing.contains(type))
            #expect(blind.contains(type))
        }
    }
}
