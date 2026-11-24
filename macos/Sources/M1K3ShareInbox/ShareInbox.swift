//
//  ShareInbox.swift
//  M1K3ShareInbox
//
//  Share to M1K3, slice 2 (1.6, #893): selected text, a web link or a file shared from ANY app's share sheet
//  (Safari, Notes, Mail) lands in M1K3's composer, staged and never sent. Slice 1 (#895, SharedFileIntake) covers
//  "Open in…" for files; document types never put M1K3 in the share sheet's app row for text or links. This is
//  the drop box between the two processes that slice needs:
//
//    share extension (M1K3ShareExtension) ── DropWriter ──▶ <App Group>/ShareInbox/<ms>-<uuid>/
//    app (RootView, on activation)        ◀── pending ───── draft.txt + files/*  → composer draft / ＋ attach
//    chat (ChatScreen, once staged)       ─── discard ───▶ the drop leaves the group container
//
//  Why an App Group and not a hand-off that opens the app (researched on the iOS 27.2 SDK, 2026-11-23):
//  `NSExtensionContext.open(_:)` is honoured only by the Today and iMessage extension points (Apple's doc on
//  that method), so a share extension cannot bring M1K3 forward and says "Open M1K3 to see it" instead. App
//  Intents have no share-sheet surface (the AppIntents interface has `supportedModes`, nothing that registers
//  an intent in another app's share sheet). The responder-chain `openURL:` trick is an App Review risk: not used.
//  The App Group (`group.app.m1k3`) is the documented way an extension and its app share files; it needs the
//  group registered in the developer portal on both App IDs before a device or store build.
//
//  Everything here is Foundation + UniformTypeIdentifiers only, so the extension (a tight memory ceiling) links
//  it without the chat stack. No network: a web link is TEXT, never fetched; nothing here sends anything.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.8 (pure + temp-folder tested; the share sheet, the
//  App Group container and the hand-off timing are verify-on-device). Prior: Unknown (new file).
//  Review: Kev + claude-opus-5-5, 2026-11-23 (pre-push review fold) — claim then kill lost the share: `claimAll` deleted
//  the drop once read, leaving it only in app memory and tmp. Now `pending` reads drops where they lie, `unseen` dedupes
//  a second claim by drop name, and only `discard`, after the chat has staged a drop, deletes it (the holding folder is
//  gone). `readText` reads shared text from disk up to the cap; `body` and `placement` cap before counting; `addFile`
//  refuses symlinks and folders. Confidence 0.85 (pure + temp-folder tested; the hand-off is Simulator-verified).
//

import Foundation
import UniformTypeIdentifiers

public enum ShareInbox {
    /// The App Group both the app and its share extension carry (entitlements; registered in the portal by Kev).
    public static let appGroup = "group.app.m1k3"
    /// The folder in the group container the extension drops into.
    public static let inboxFolderName = "ShareInbox"
    /// Posted (Darwin notify) by the extension after a drop, so an app already on screen (iPad Split View) claims it.
    /// Any process can post this name: the worst a stray post does is one extra claim, which finds nothing new.
    public static let droppedNotification = "app.m1k3.share.dropped"

    /// Text up to this many characters becomes a composer draft; longer text is staged as a text file, so a pasted
    /// article doesn't flood the text field.
    public static let draftLimit = 2000
    /// The most text kept from one share: FileTextExtractor's own cap, so a shared text file reads the same.
    public static let textCap = 50000
    /// The biggest file the extension copies. Text this size is already far past `textCap`.
    public static let fileByteCap = 5 * 1024 * 1024
    /// The most attachments taken from one share.
    public static let itemCap = 5
    /// A drop no one opened M1K3 to claim within this long is deleted unread.
    public static let lifetime: TimeInterval = 24 * 60 * 60

    /// The ＋ picker's file types (AttachmentRouting.fileTypes; SharedFileIntakeTests pins the two lists equal).
    public static let fileTypeIdentifiers = [
        "public.plain-text", "public.text", "public.source-code", "public.json", "public.yaml", "public.xml",
        "public.html",
    ]

    // MARK: - What an attachment is

    /// How the extension loads one attachment, from the type identifiers it registers.
    public enum Route: Equatable, Sendable {
        /// A file handed over by URL (Files, Mail attachments): copy it if its type is readable.
        case fileURL
        /// A web page link: kept as text, never fetched.
        case link
        /// Plain text: a selection (Notes, Safari) or a .txt file. What loads decides: a string or a file.
        case textOrFile
        /// Another readable type (JSON, HTML, code…), loaded as a file of this type.
        case file(String)
        /// Images, PDFs and anything the ＋ picker's file path can't read.
        case unsupported
    }

    public static func route(_ registeredTypes: [String]) -> Route {
        let types = registeredTypes.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return .fileURL }
        if types.contains(where: { $0.conforms(to: .url) }) { return .link }
        if types.contains(where: { $0.conforms(to: .plainText) }) { return .textOrFile }
        if let readable = types.first(where: isReadable) { return .file(readable.identifier) }
        return .unsupported
    }

    /// A file is taken when its name's type is one the ＋ picker reads.
    public static func accepts(fileNamed name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return isReadable(type)
    }

    /// The name a file loaded by type is saved under: the sender's suggested name, given the type's extension when
    /// it has none, and never a path (a "/" would climb out of the drop folder).
    public static func fileName(suggested: String?, typeIdentifier: String) -> String {
        let trimmed = (suggested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let base = trimmed.isEmpty ? "Shared" : trimmed
        guard (base as NSString).pathExtension.isEmpty,
              let ext = UTType(typeIdentifier)?.preferredFilenameExtension else { return base }
        return "\(base).\(ext)"
    }

    private static func isReadable(_ type: UTType) -> Bool {
        fileTypeIdentifiers.compactMap { UTType($0) }.contains { type.conforms(to: $0) }
    }

    // MARK: - Shaping text

    /// The words a share carries: each text, then each link on its own line, capped at `textCap`.
    public struct Body: Equatable, Sendable {
        public var text: String
        /// Cut at `textCap`; the extension says so.
        public var truncated: Bool

        public init(text: String, truncated: Bool) {
            self.text = text
            self.truncated = truncated
        }
    }

    /// Each piece is cut to just past the cap BEFORE anything else, so a huge share is never counted or copied whole.
    public static func body(texts: [String], links: [URL]) -> Body? {
        let linkLines = links.map(\.absoluteString)
        var parts = texts
            .map { String($0.prefix(textCap + 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !linkLines.contains($0) }
        parts += linkLines
        let capped = parts.joined(separator: "\n\n").prefix(textCap + 1)
        guard !capped.isEmpty else { return nil }
        guard capped.count > textCap else { return Body(text: String(capped), truncated: false) }
        return Body(text: String(capped.prefix(textCap)), truncated: true)
    }

    public enum Placement: Equatable, Sendable {
        /// Into the composer as words the person can edit.
        case draft
        /// Staged as a text file, the way a file picked with ＋ is.
        case textFile
    }

    public static func placement(of text: String) -> Placement {
        text.prefix(draftLimit + 1).count <= draftLimit ? .draft : .textFile
    }

    /// A shared draft lands AFTER what the person already typed, never in place of it.
    public static func merge(draft: String, shared: [String]) -> String {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = (typed.isEmpty ? [] : [draft]) + shared.filter { !$0.isEmpty }
        return parts.isEmpty ? draft : parts.joined(separator: "\n\n")
    }

    // MARK: - The drop on disk

    /// Why the extension turned an attachment away.
    public enum Refusal: Error, Equatable, Sendable {
        case tooBig
        case notReadable
    }

    static let draftFileName = "draft.txt"
    static let filesFolderName = "files"

    /// `<milliseconds since 1970>-<uuid>`: the claim orders and expires drops by name, reading no file dates.
    public static func folderName(created: Date, id: UUID) -> String {
        "\(Int64((created.timeIntervalSince1970 * 1000).rounded()))-\(id.uuidString)"
    }

    public static func created(folderName: String) -> Date? {
        guard let dash = folderName.firstIndex(of: "-"), let ms = Int64(folderName[..<dash]) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// Writes one drop into a hidden folder and renames it into place on `commit`, so the app never claims half.
    public struct DropWriter: Sendable {
        public let staging: URL
        public let destination: URL

        public init(inbox: URL, now: Date = .now, id: UUID = UUID()) throws {
            let name = ShareInbox.folderName(created: now, id: id)
            staging = inbox.appending(path: "." + name)
            destination = inbox.appending(path: name)
            try FileManager.default.createDirectory(
                at: staging.appending(path: ShareInbox.filesFolderName), withIntermediateDirectories: true
            )
        }

        public func setDraft(_ text: String) throws {
            try Data(text.utf8).write(to: staging.appending(path: ShareInbox.draftFileName), options: .atomic)
        }

        /// Copies (never moves) a readable file under the byte cap; a second file with the same name gets " 2".
        /// Only a regular file: a symlink's size is the link's (and copying it would copy the link), a folder has no
        /// size at all, so both are refused whatever their names say.
        @discardableResult
        public func addFile(copying source: URL, named name: String? = nil) throws -> URL {
            let fileName = name ?? source.lastPathComponent
            guard ShareInbox.accepts(fileNamed: fileName) else { throw Refusal.notReadable }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw Refusal.notReadable }
            guard let size = values.fileSize, size <= ShareInbox.fileByteCap else { throw Refusal.tooBig }
            let target = uniqueURL(for: fileName)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }

        /// Text too long for a draft, staged as a file of its own.
        @discardableResult
        public func addTextFile(_ text: String, named name: String) throws -> URL {
            let target = uniqueURL(for: name)
            try Data(text.utf8).write(to: target, options: .atomic)
            return target
        }

        public func commit() throws {
            try FileManager.default.moveItem(at: staging, to: destination)
        }

        public func discard() {
            try? FileManager.default.removeItem(at: staging)
        }

        private func uniqueURL(for name: String) -> URL {
            let folder = staging.appending(path: ShareInbox.filesFolderName)
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var candidate = folder.appending(path: name)
            var n = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            return candidate
        }
    }

    /// One committed share, read where it lies in the group container. Nothing is moved or deleted by reading it:
    /// the drop stays until the chat has staged it (`discard`), so a kill between claim and stage loses nothing.
    public struct Drop: Equatable, Sendable, Identifiable {
        /// The folder name, `<ms>-<uuid>`: unique per share, the key a second claim dedupes on.
        public let name: String
        public let folder: URL
        /// Words for the composer, if the share carried any.
        public let draft: String?
        /// Files for the ＋ picker's `attach`, inside `folder`.
        public let files: [URL]

        public var id: String {
            name
        }
    }

    /// Every committed, fresh drop, oldest first, read without moving or deleting anything, so a claim can be
    /// interrupted and read again. Only drops past `lifetime`, and half-writes that old, are deleted (unread).
    /// The age is wall-clock time from the drop's name: a clock set back keeps a drop longer, never loses one early
    /// unless the clock jumps a day forward.
    public static func pending(inbox: URL, now: Date = .now) -> [Drop] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: inbox.path)) ?? []
        var fresh: [(Date, String)] = []
        for name in names {
            let written = created(folderName: name.hasPrefix(".") ? String(name.dropFirst()) : name)
            let expired = written.map { now.timeIntervalSince($0) > lifetime } ?? true
            if expired {
                try? fm.removeItem(at: inbox.appending(path: name))
            } else if let written, !name.hasPrefix(".") {
                fresh.append((written, name))
            }
        }
        return fresh.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { _, name in
            let folder = inbox.appending(path: name)
            let files = folder.appending(path: filesFolderName)
            let fileNames = ((try? fm.contentsOfDirectory(atPath: files.path)) ?? []).sorted()
            return Drop(
                name: name,
                folder: folder,
                draft: readText(at: folder.appending(path: draftFileName)),
                files: fileNames.map { files.appending(path: $0) }
            )
        }
    }

    /// The drops not already claimed in this run (waiting to be staged, or staged), by drop name.
    public static func unseen(_ drops: [Drop], seen: Set<String>) -> [Drop] {
        drops.filter { !seen.contains($0.name) }
    }

    /// Deletes a drop from the group container. Only once the chat has staged it.
    public static func discard(_ drop: Drop) {
        try? FileManager.default.removeItem(at: drop.folder)
    }

    /// Up to `cap` characters of a UTF-8 text file, reading at most `cap * 4` bytes (UTF-8's widest character), so a
    /// huge share never lands in memory whole. A read that ends mid-character drops the partial bytes. Nil for no
    /// file, an empty one, or bytes that aren't UTF-8.
    public static func readText(at url: URL, cap: Int = textCap) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: cap * 4), !data.isEmpty else { return nil }
        for trim in 0 ... min(3, data.count - 1) {
            if let text = String(bytes: data.dropLast(trim), encoding: .utf8) {
                return String(text.prefix(cap))
            }
        }
        return nil
    }
}
