//
//  ShareViewController.swift
//  M1K3ShareExtension
//
//  "Share to M1K3" from ANY app's share sheet (Safari, Notes, Mail), slice 2 of 1.6 (#893). Selected text, a web
//  link or a text file is dropped into the App Group inbox (M1K3ShareInbox); M1K3 claims it into a new chat's
//  composer the next time it comes forward, staged and never sent (slice 1's path, ChatScreen.receiveSharedFiles).
//
//  The route, and why (iOS 27.2 SDK, researched 2026-11-23):
//  - A share extension cannot open its app. `NSExtensionContext.open(_:)` works only for the Today and iMessage
//    extension points (Apple's documentation of that method), so the card says "Open M1K3 to see it".
//  - App Intents have no share-sheet surface: the AppIntents interface offers `supportedModes` (foreground or
//    background for an intent already running), and nothing that lists an intent in another app's share sheet.
//    Only the user's own Shortcuts can sit there.
//  - The responder-chain `openURL:` trick is an App Review risk, so it is not used (a scan test forbids it).
//  - Document types (slice 1) never put M1K3 in the app row for text or links. So: a Share Extension and an App
//    Group (`group.app.m1k3`), Apple's documented way for an extension to hand data to its app. The group must be
//    registered in the developer portal on app.m1k3 and app.m1k3.share before a device or store build.
//
//  Memory: no chat stack, no MLX, only M1K3ShareInbox (Foundation). Files are copied on disk, never read whole
//  (5 MB cap); text is capped at 50,000 characters. No network: a link is kept as words, never fetched.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.7 (builds for the Simulator; the share sheet on a real
//  device, the App Group signing and the card's look are owed). Prior: Unknown (new file).
//

import M1K3ShareInbox
import notify
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The extension's principal class (NSExtensionPrincipalClass): hosts the card and finishes the request.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let card = UIHostingController(rootView: ShareCard(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(card)
        card.view.frame = view.bounds
        card.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(card.view)
        card.didMove(toParent: self)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = Array(items.flatMap { $0.attachments ?? [] }.prefix(ShareInbox.itemCap))
        Task { await model.take(providers) }
    }
}

/// What one share came to, for the card.
@MainActor @Observable
final class ShareModel {
    enum Outcome: Equatable {
        case working
        /// Dropped into the inbox. `cut`: text past the cap was cut; `leftOut`: attachments M1K3 can't read yet.
        case added(cut: Bool, leftOut: Int)
        /// Nothing M1K3 can read: images, PDFs, too big.
        case nothing
        /// The inbox couldn't be written (no App Group on this build, or a full disk).
        case failed
    }

    private(set) var outcome = Outcome.working

    func take(_ providers: [NSItemProvider]) async {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareInbox.appGroup)
        else {
            outcome = .failed
            return
        }
        let writer: ShareInbox.DropWriter
        do {
            writer = try ShareInbox.DropWriter(inbox: group.appending(path: ShareInbox.inboxFolderName))
        } catch {
            outcome = .failed
            return
        }
        var texts: [String] = []
        var links: [URL] = []
        var files = 0
        var leftOut = 0
        for provider in providers {
            switch await Loader.load(provider, into: writer) {
            case let .text(text): texts.append(text)
            case let .link(url): links.append(url)
            case .file: files += 1
            case .skipped: leftOut += 1
            }
        }
        let body = ShareInbox.body(texts: texts, links: links)
        do {
            if let body {
                switch ShareInbox.placement(of: body.text) {
                case .draft:
                    try writer.setDraft(body.text)
                case .textFile:
                    let name = String(localized: "Shared text", comment: "The file name for long shared text")
                    try writer.addTextFile(body.text, named: name + ".txt")
                }
            }
            guard body != nil || files > 0 else {
                writer.discard()
                outcome = .nothing
                return
            }
            try writer.commit()
        } catch {
            writer.discard()
            outcome = .failed
            return
        }
        // Tells an M1K3 already on screen (iPad Split View) to claim it now; otherwise it claims on its next launch.
        notify_post(ShareInbox.droppedNotification)
        outcome = .added(cut: body?.truncated == true, leftOut: leftOut)
    }
}

/// Loads one attachment by its route. Files are copied into the drop inside the provider's callback, where the
/// system's temporary copy is still valid; text and links come back as words. Main-actor bound, so a provider (not
/// Sendable) never leaves the actor; only the callbacks run elsewhere, and they capture Sendable values alone.
@MainActor
enum Loader {
    enum Loaded {
        case text(String)
        case link(URL)
        case file
        case skipped
    }

    private enum Item {
        case url(URL)
        case string(String)
        case data(Data)
        case none
    }

    static func load(_ provider: NSItemProvider, into writer: ShareInbox.DropWriter) async -> Loaded {
        switch ShareInbox.route(provider.registeredTypeIdentifiers) {
        case .fileURL:
            guard case let .url(url) = await item(provider, UTType.fileURL.identifier) else { return .skipped }
            return copy(url, into: writer)
        case .link:
            guard case let .url(url) = await item(provider, UTType.url.identifier) else { return .skipped }
            // A web link is words: it is never fetched. A file URL shared as a link is a file.
            return url.isFileURL ? copy(url, into: writer) : .link(url)
        case .textOrFile:
            switch await item(provider, UTType.plainText.identifier) {
            case let .string(text): return .text(text)
            case let .url(url) where url.isFileURL: return copy(url, into: writer)
            case let .data(data) where data.count <= ShareInbox.fileByteCap:
                // Not UTF-8 is not text M1K3 can read: left out, never shown as replacement characters.
                return String(bytes: data, encoding: .utf8).map(Loaded.text) ?? .skipped
            default: return .skipped
            }
        case let .file(type):
            let name = ShareInbox.fileName(suggested: provider.suggestedName, typeIdentifier: type)
            return await copyRepresentation(provider, type: type, named: name, into: writer)
        case .unsupported:
            return .skipped
        }
    }

    private static func copy(_ url: URL, into writer: ShareInbox.DropWriter) -> Loaded {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? writer.addFile(copying: url)) == nil ? .skipped : .file
    }

    private static func item(_ provider: NSItemProvider, _ type: String) async -> Item {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                switch value {
                case let url as URL: continuation.resume(returning: .url(url))
                case let text as String: continuation.resume(returning: .string(text))
                case let data as Data: continuation.resume(returning: .data(data))
                default: continuation.resume(returning: .none)
                }
            }
        }
    }

    private static func copyRepresentation(
        _ provider: NSItemProvider, type: String, named name: String, into writer: ShareInbox.DropWriter
    ) async -> Loaded {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                // The system's copy lives only until this callback returns, so it is copied here.
                guard let url, (try? writer.addFile(copying: url, named: name)) != nil else {
                    continuation.resume(returning: .skipped)
                    return
                }
                continuation.resume(returning: .file)
            }
        }
    }
}

/// The card the share sheet shows: short, plain words (Kev is dyslexic), one button.
struct ShareCard: View {
    let model: ShareModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            Button(action: done) {
                Text(String(localized: "Done", comment: "Closes the share card"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.outcome == .working)
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch model.outcome {
        case .working: "ellipsis"
        case .added: "checkmark.circle"
        case .nothing, .failed: "exclamationmark.circle"
        }
    }

    private var title: String {
        switch model.outcome {
        case .working: String(localized: "Adding to M1K3…", comment: "Share card title while the share is saved")
        case .added: String(localized: "Added to M1K3", comment: "Share card title once the share is saved")
        case .nothing:
            String(localized: "M1K3 can't read this yet", comment: "Share card title for images, PDFs, big files")
        case .failed: String(localized: "That didn't work", comment: "Share card title when saving failed")
        }
    }

    private var lines: [String] {
        switch model.outcome {
        case .working:
            return []
        case let .added(cut, leftOut):
            var lines = [
                String(localized: "Open M1K3 to see it.", comment: "Share card: M1K3 can't open itself from here"),
                String(
                    localized: "Nothing is sent until you send it.", comment: "Share card: the share is staged, not sent"
                ),
            ]
            if cut {
                lines.append(String(
                    localized: "It was long, so M1K3 kept the first part.", comment: "Share card: text was cut"
                ))
            }
            if leftOut > 0 {
                lines.append(String(
                    localized: "M1K3 left out what it can't read yet.", comment: "Share card: some items were skipped"
                ))
            }
            return lines
        case .nothing:
            return [String(
                localized: "It takes text, links and text files.", comment: "Share card: what M1K3 can take"
            )]
        case .failed:
            return [String(localized: "Please try again.", comment: "Share card: saving failed")]
        }
    }
}
