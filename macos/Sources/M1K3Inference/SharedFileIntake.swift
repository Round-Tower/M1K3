//
//  SharedFileIntake.swift
//  M1K3Inference
//
//  A file shared to M1K3 from another app (AirDrop, Files, Share → Open in) lands staged in the composer of a
//  new chat, exactly as if it had been picked with ＋, and is never sent (1.6, #893 C; Kev 2026-11-22: "I wish I
//  could have shared the JSON file directly to M1K3 - instead of save, and open M1K3 then open the file"). The
//  shell (RootView / ChatScreen) only moves URLs; every decision is here: what arrived, when the chat can take
//  it, which copy is ours to delete, and which types the plist registers (the ＋ picker's own file types, so a
//  shared file can never be a kind the picker refuses). Staging goes through the same `attach` as ＋, so a shared
//  file follows the same on-device rules: files never ride a Private Cloud turn (ADR 0010).
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.8 (pure + tested; the share sheet, AirDrop and cold
//  launch are verify-on-device). Prior: Unknown.
//

import Foundation
import UniformTypeIdentifiers

public enum SharedFileIntake {
    /// What a URL handed to the app is.
    public enum Arrival: Equatable, Sendable {
        /// An `m1k3://` link: open the chat screen.
        case deepLink
        /// A local file another app handed over: stage it.
        case file(URL)
        /// Anything else.
        case ignore
    }

    /// When the chat can take a shared file. There is deliberately no step that sends.
    public enum Step: Equatable, Hashable, Sendable {
        /// A turn is answering: a new chat can't start mid-turn, and the file must not join that turn.
        case wait
        /// The chat is empty: stage it here.
        case stageHere
        /// The chat has messages: start a new chat, then stage it.
        case newChatThenStage
    }

    public static func classify(_ url: URL) -> Arrival {
        if DeepLink(url: url) != nil { return .deepLink }
        return url.isFileURL ? .file(url) : .ignore
    }

    public static func step(isResponding: Bool, hasMessages: Bool) -> Step {
        if isResponding { return .wait }
        return hasMessages ? .newChatThenStage : .stageHere
    }

    /// iOS copies a file opened in another app into `Documents/Inbox` (the plist opts out of opening in place).
    /// Once its text or image is staged, that copy is ours to delete: nothing of the user's lingers there.
    public static func isSystemInboxCopy(_ url: URL, documents: URL) -> Bool {
        let inbox = documents.appending(path: "Inbox").standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        return path.count > inbox.count && Array(path.prefix(inbox.count)) == inbox
    }

    /// The UTIs the iPhone plist registers under CFBundleDocumentTypes: the ＋ picker's file types. Images and
    /// PDFs are not registered in slice 1 (PDFs go through Documents on the phone today; that decision is owed).
    public static var registeredTypeIdentifiers: [String] {
        AttachmentRouting.fileTypes.map(\.identifier)
    }
}
