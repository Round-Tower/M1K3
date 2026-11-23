//
//  ShareInboxTests.swift
//  M1K3ShareInboxTests
//
//  Share to M1K3, slice 2 (1.6, #893): text, a web link or a file shared from ANY app's share sheet is dropped by
//  the share extension into the App Group's inbox, and the app claims it into the composer, staged and never sent.
//  These pin the pure decisions and the on-disk drop: what an attachment is, how text is shaped, the caps, the
//  atomic write, the claim (fresh first, expired unread), and which copies are ours to delete.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.8 (pure + temp-folder I/O; the share sheet itself is
//  verify-on-device). Prior: Unknown (new file).
//

import Foundation
@testable import M1K3ShareInbox
import Testing

struct ShareInboxRouteTests {
    @Test("a file handed over by URL is a file; a web link is a link, never a file to fetch")
    func fileURLAndLink() {
        #expect(ShareInbox.route(["public.file-url", "public.url"]) == .fileURL)
        #expect(ShareInbox.route(["public.url"]) == .link)
        #expect(ShareInbox.route(["public.url", "public.plain-text"]) == .link)
    }

    @Test("plain text (a selection in Notes, or a .txt) is decided by what loads; other readable types load as files")
    func textAndFiles() {
        #expect(ShareInbox.route(["public.utf8-plain-text"]) == .textOrFile)
        #expect(ShareInbox.route(["public.plain-text"]) == .textOrFile)
        #expect(ShareInbox.route(["public.json"]) == .file("public.json"))
        #expect(ShareInbox.route(["public.html"]) == .file("public.html"))
    }

    @Test("images, PDFs and anything else the ＋ picker's file path can't read are refused, by name")
    func unsupported() {
        #expect(ShareInbox.route(["public.jpeg"]) == .unsupported)
        #expect(ShareInbox.route(["com.adobe.pdf"]) == .unsupported)
        #expect(ShareInbox.route([]) == .unsupported)
    }

    @Test("a file loaded by type keeps the sender's name, with the type's extension when the name has none")
    func fileName() {
        #expect(ShareInbox.fileName(suggested: "notes.json", typeIdentifier: "public.json") == "notes.json")
        #expect(ShareInbox.fileName(suggested: "notes", typeIdentifier: "public.json") == "notes.json")
        #expect(ShareInbox.fileName(suggested: nil, typeIdentifier: "public.html") == "Shared.html")
        #expect(ShareInbox.fileName(suggested: "  ", typeIdentifier: "public.plain-text") == "Shared.txt")
        #expect(ShareInbox.fileName(suggested: "a/b.txt", typeIdentifier: "public.plain-text") == "a-b.txt",
                "a name never climbs out of the drop")
    }

    @Test("a file is accepted by its name's type: text and code yes, PDF and photos no")
    func acceptsByName() {
        for name in ["notes.txt", "data.json", "page.html", "main.swift", "config.yaml"] {
            #expect(ShareInbox.accepts(fileNamed: name), "\(name)")
        }
        for name in ["paper.pdf", "IMG_0001.HEIC", "photo.jpg", "noextension"] {
            #expect(!ShareInbox.accepts(fileNamed: name), "\(name)")
        }
    }
}

struct ShareInboxBodyTests {
    @Test("text comes first, then each link on its own line; a link repeated as text is said once")
    func shape() throws {
        let link = try #require(URL(string: "https://example.com/a"))
        let body = ShareInbox.body(texts: ["  A page I liked  ", "https://example.com/a"], links: [link])
        #expect(body == ShareInbox.Body(text: "A page I liked\n\nhttps://example.com/a", truncated: false))
    }

    @Test("nothing but whitespace is no body at all")
    func empty() {
        #expect(ShareInbox.body(texts: ["  ", "\n"], links: []) == nil)
    }

    @Test("text past the cap is cut, and says so")
    func capped() {
        let long = String(repeating: "a", count: ShareInbox.textCap + 10)
        let body = ShareInbox.body(texts: [long], links: [])
        #expect(body?.text.count == ShareInbox.textCap)
        #expect(body?.truncated == true)
    }

    @Test("short text is a composer draft; long text is staged as a text file, like a file picked with ＋")
    func placement() {
        #expect(ShareInbox.placement(of: String(repeating: "a", count: ShareInbox.draftLimit)) == .draft)
        #expect(ShareInbox.placement(of: String(repeating: "a", count: ShareInbox.draftLimit + 1)) == .textFile)
    }

    @Test("a shared draft joins what the person already typed, after it, never in place of it")
    func merge() {
        #expect(ShareInbox.merge(draft: "", shared: ["hello"]) == "hello")
        #expect(ShareInbox.merge(draft: "my question", shared: ["hello", "world"]) == "my question\n\nhello\n\nworld")
        #expect(ShareInbox.merge(draft: "  ", shared: ["x"]) == "x")
        #expect(ShareInbox.merge(draft: "kept", shared: []) == "kept")
    }

    @Test("the extension's file types are the ＋ picker's own")
    func types() {
        #expect(ShareInbox.fileTypeIdentifiers.contains("public.json"))
        #expect(!ShareInbox.fileTypeIdentifiers.contains("com.adobe.pdf"))
        #expect(!ShareInbox.fileTypeIdentifiers.contains("public.image"))
    }
}

struct ShareInboxDropTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ShareInboxTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ name: String, _ text: String, in folder: URL) throws -> URL {
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("a drop's folder name carries its time, so the claim can order and expire it without reading file dates")
    func folderName() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000.123)
        let name = ShareInbox.folderName(created: when, id: UUID())
        let back = try #require(ShareInbox.created(folderName: name))
        #expect(abs(back.timeIntervalSince(when)) < 0.001)
        #expect(ShareInbox.created(folderName: "junk") == nil)
        #expect(ShareInbox.created(folderName: "." + name) == nil, "a drop still being written is not a drop")
    }

    @Test("a drop is invisible until it is committed, then the claim takes it: the draft and the file, in order")
    func writeThenClaim() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appending(path: "inbox")
        let holding = root.appending(path: "holding")
        let source = try file("notes.json", "{}", in: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let writer = try ShareInbox.DropWriter(inbox: inbox, now: now)
        try writer.setDraft("look at this")
        _ = try writer.addFile(copying: source)
        #expect(ShareInbox.claimAll(inbox: inbox, holding: holding, now: now) == ShareInbox.Claimed(),
                "half-written drops are never claimed")
        try writer.commit()

        let claimed = ShareInbox.claimAll(inbox: inbox, holding: holding, now: now.addingTimeInterval(5))
        #expect(claimed.drafts == ["look at this"])
        #expect(claimed.files.map(\.lastPathComponent) == ["notes.json"])
        let moved = try #require(claimed.files.first)
        #expect(try String(contentsOf: moved, encoding: .utf8) == "{}")
        #expect(ShareInbox.holdingDrop(of: moved, holding: holding) != nil, "the file now waits in our holding folder")
        #expect(FileManager.default.fileExists(atPath: source.path), "the source is copied, never moved")
        // Claimed once: the drop is gone from the shared container.
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty)
        #expect(ShareInbox.claimAll(inbox: inbox, holding: holding, now: now) == ShareInbox.Claimed())
    }

    @Test("drops are claimed oldest first")
    func order() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appending(path: "inbox")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (offset, text) in [(20.0, "second"), (10.0, "first")] {
            let writer = try ShareInbox.DropWriter(inbox: inbox, now: now.addingTimeInterval(offset))
            try writer.setDraft(text)
            try writer.commit()
        }
        let holding = root.appending(path: "h")
        let claimed = ShareInbox.claimAll(inbox: inbox, holding: holding, now: now.addingTimeInterval(30))
        #expect(claimed.drafts == ["first", "second"])
    }

    @Test("a drop older than its lifetime is deleted unread: shared words don't wait around for days")
    func expiry() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appending(path: "inbox")
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        let writer = try ShareInbox.DropWriter(inbox: inbox, now: then)
        try writer.setDraft("old")
        try writer.commit()
        // A writer that never committed (the extension was killed) is swept too, once it is that old.
        let abandoned = try ShareInbox.DropWriter(inbox: inbox, now: then)
        try abandoned.setDraft("half")

        let later = then.addingTimeInterval(ShareInbox.lifetime + 1)
        let holding = root.appending(path: "h")
        #expect(ShareInbox.claimAll(inbox: inbox, holding: holding, now: later) == ShareInbox.Claimed())
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty)
    }

    @Test("a file over the cap is refused before it is copied")
    func byteCap() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appending(path: "big.txt")
        try Data(count: ShareInbox.fileByteCap + 1).write(to: big)
        let writer = try ShareInbox.DropWriter(inbox: root.appending(path: "inbox"))
        #expect(throws: ShareInbox.Refusal.tooBig) { try writer.addFile(copying: big) }
        #expect(throws: ShareInbox.Refusal.notReadable) {
            try writer.addFile(copying: file("paper.pdf", "%PDF", in: root))
        }
    }

    @Test("two files with one name both arrive")
    func nameCollision() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appending(path: "a")
        let b = root.appending(path: "b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let writer = try ShareInbox.DropWriter(inbox: root.appending(path: "inbox"))
        let first = try writer.addFile(copying: file("notes.txt", "1", in: a))
        let second = try writer.addFile(copying: file("notes.txt", "2", in: b))
        #expect(first.lastPathComponent == "notes.txt")
        #expect(second.lastPathComponent == "notes 2.txt")
    }

    @Test("a held file's drop folder is ours to delete once staged; a file anywhere else is not")
    func holdingDrop() {
        let holding = URL(fileURLWithPath: "/private/var/mobile/X/tmp/SharedToM1K3")
        let file = holding.appending(path: "123-abc/notes.json")
        #expect(ShareInbox.holdingDrop(of: file, holding: holding) == holding.appending(path: "123-abc"))
        // iOS names tmp under /private/var and /var both: one place.
        let viaVar = URL(fileURLWithPath: "/var/mobile/X/tmp/SharedToM1K3/123-abc/notes.json")
        #expect(ShareInbox.holdingDrop(of: viaVar, holding: holding) != nil)
        #expect(ShareInbox.holdingDrop(of: holding.appending(path: "loose.json"), holding: holding) == nil)
        let elsewhere = URL(fileURLWithPath: "/var/mobile/X/Documents/notes.json")
        #expect(ShareInbox.holdingDrop(of: elsewhere, holding: holding) == nil)
        #expect(ShareInbox.holdingDrop(of: holding.appending(path: "123-abc/../../x.json"), holding: holding) == nil)
    }

    @Test("held drops no file is waiting on are leftovers to sweep")
    func unclaimed() {
        let holding = URL(fileURLWithPath: "/var/mobile/X/tmp/SharedToM1K3")
        let kept = holding.appending(path: "1-a")
        let stale = holding.appending(path: "2-b")
        let waiting = [kept.appending(path: "notes.json")]
        #expect(ShareInbox.unclaimed([kept, stale], waiting: waiting, holding: holding) == [stale])
        #expect(ShareInbox.unclaimed([kept, stale], waiting: [], holding: holding) == [kept, stale])
    }
}
