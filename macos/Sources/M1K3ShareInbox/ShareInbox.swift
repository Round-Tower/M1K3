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
//    app (RootView, on activation)        ◀── claimAll ──── draft.txt + files/*  → composer draft / ＋ attach
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
//

import Foundation
import UniformTypeIdentifiers

public enum ShareInbox {
    /// The App Group both the app and its share extension carry (entitlements; registered in the portal by Kev).
    public static let appGroup = "group.app.m1k3"
    /// The folder in the group container the extension drops into.
    public static let inboxFolderName = "ShareInbox"
    /// The app's own folder (under its tmp) where a claimed file waits to be staged.
    public static let holdingFolderName = "SharedToM1K3"
    /// Posted (Darwin notify) by the extension after a drop, so an app already on screen (iPad Split View) claims it.
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

    public static func body(texts: [String], links: [URL]) -> Body? {
        let linkLines = links.map(\.absoluteString)
        var parts = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !linkLines.contains($0) }
        parts += linkLines
        let joined = parts.joined(separator: "\n\n")
        guard !joined.isEmpty else { return nil }
        guard joined.count > textCap else { return Body(text: joined, truncated: false) }
        return Body(text: String(joined.prefix(textCap)), truncated: true)
    }

    public enum Placement: Equatable, Sendable {
        /// Into the composer as words the person can edit.
        case draft
        /// Staged as a text file, the way a file picked with ＋ is.
        case textFile
    }

    public static func placement(of text: String) -> Placement {
        text.count <= draftLimit ? .draft : .textFile
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
        @discardableResult
        public func addFile(copying source: URL, named name: String? = nil) throws -> URL {
            let fileName = name ?? source.lastPathComponent
            guard ShareInbox.accepts(fileNamed: fileName) else { throw Refusal.notReadable }
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ShareInbox.fileByteCap else { throw Refusal.tooBig }
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

    /// What the app took from the inbox: drafts for the composer, files for the ＋ picker's `attach`.
    public struct Claimed: Equatable, Sendable {
        public var drafts: [String] = []
        public var files: [URL] = []

        public init(drafts: [String] = [], files: [URL] = []) {
            self.drafts = drafts
            self.files = files
        }
    }

    /// Takes every committed, fresh drop (oldest first): its draft is read, its files MOVE into `holding/<drop>/`,
    /// and the drop leaves the shared container. Expired drops and abandoned half-writes are deleted unread.
    public static func claimAll(inbox: URL, holding: URL, now: Date = .now) -> Claimed {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: inbox.path)) ?? []
        var fresh: [(Date, String)] = []
        for name in names {
            let folder = inbox.appending(path: name)
            let written = created(folderName: name.hasPrefix(".") ? String(name.dropFirst()) : name)
            let expired = written.map { now.timeIntervalSince($0) > lifetime } ?? true
            if expired {
                try? fm.removeItem(at: folder)
            } else if let written, !name.hasPrefix(".") {
                fresh.append((written, name))
            }
        }
        var claimed = Claimed()
        for (_, name) in fresh.sorted(by: { $0.0 < $1.0 }) {
            let folder = inbox.appending(path: name)
            if let data = fm.contents(atPath: folder.appending(path: draftFileName).path),
               let text = String(data: data, encoding: .utf8), !text.isEmpty
            {
                claimed.drafts.append(text)
            }
            let files = folder.appending(path: filesFolderName)
            let fileNames = ((try? fm.contentsOfDirectory(atPath: files.path)) ?? []).sorted()
            if !fileNames.isEmpty {
                let held = holding.appending(path: name)
                try? fm.createDirectory(at: held, withIntermediateDirectories: true)
                for fileName in fileNames {
                    let target = held.appending(path: fileName)
                    if (try? fm.moveItem(at: files.appending(path: fileName), to: target)) != nil {
                        claimed.files.append(target)
                    }
                }
            }
            try? fm.removeItem(at: folder)
        }
        return claimed
    }

    /// The `holding/<drop>` folder a claimed file waits in, or nil for a file anywhere else. Once the file is
    /// staged that folder is ours to delete.
    public static func holdingDrop(of url: URL, holding: URL) -> URL? {
        let root = components(holding)
        let path = components(url)
        guard path.count == root.count + 2, Array(path.prefix(root.count)) == root else { return nil }
        return holding.appending(path: path[root.count])
    }

    /// Held drop folders no waiting file lives in: swept when the app goes to the background.
    public static func unclaimed(_ folders: [URL], waiting: [URL], holding: URL) -> [URL] {
        let busy = Set(waiting.compactMap { holdingDrop(of: $0, holding: holding) }.map(components))
        return folders.filter { !busy.contains(components($0)) }
    }

    /// Path components with `..` folded and `/private/var` read as `/var` (iOS names both), without the disk.
    private static func components(_ url: URL) -> [String] {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count > 2, parts[0] == "/", parts[1] == "private", parts[2] == "var" {
            return ["/"] + parts.dropFirst(2)
        }
        return parts
    }
}
