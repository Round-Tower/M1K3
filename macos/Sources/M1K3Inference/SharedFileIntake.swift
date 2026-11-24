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
//  Review: Kev + claude-opus-5-5, 2026-11-23 (pre-push review fold) — a file waits behind the Private Cloud consent
//  sheet (it would have joined the send the sheet confirms); /private/var and /var are one place for the Inbox test;
//  `inboxLeftovers` lets the shell sweep copies a killed app left behind. Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-11-23 (#895 second and third passes) — staging deletes only its own copies;
//  the leftover sweep moves to the app going to the background. A batch AirDrop lands every copy before each URL
//  arrives and a copy keeps its source's mtime, so the age gate tried first could still take a sibling. Confidence
//  0.85 (pure + tested; a 3-file AirDrop is owed on the phone).
//  Review: Kev + claude-opus-5-5, 2026-11-23 (#893 C, the Mac half) — `admit`: the Mac's held queue for Finder's
//  Open With, a drop on the Dock icon and `open -a M1K3` (files only, in order, each once). The Mac registers the
//  same `registeredTypeIdentifiers`; `step` is shared. Confidence 0.85 (pure + tested; Open With verified by launch
//  on the Debug build, the Dock-icon drop not yet).
//  Review: Kev + claude-opus-5-5, 2026-11-23 (#898 review: a file that waits stages silently, minutes later) —
//  `waitReason` + `waitingHint`: the plain-words hint both shells show over the composer while files wait (a reply,
//  voice, or the Private Cloud sheet), plural by the catalog. Only the hint reads them; `step` still decides.
//  Confidence 0.85 (pure + tested; the wording resolves through the catalog under swift test).
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
        /// A turn is answering, or the Private Cloud consent sheet is open: a new chat can't start mid-turn, and
        /// the file must not join that turn or the send the sheet is about to confirm.
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

    public static func step(isResponding: Bool, hasMessages: Bool, consentPending: Bool) -> Step {
        if isResponding || consentPending { return .wait }
        return hasMessages ? .newChatThenStage : .stageHere
    }

    /// Why a shared file is waiting, for the hint over the composer. Only the hint reads it; `step` decides.
    public enum WaitReason: Equatable, Sendable {
        /// A reply is streaming (or a consented Private Cloud send is starting one).
        case reply
        /// Voice mode is on (the Mac stages only after it ends).
        case voice
        /// The Private Cloud consent sheet is open.
        case consent
    }

    /// The reason a file waits, or nil when `step` would stage it now. Voice outranks the sheet, which outranks a
    /// reply: the hint names the last thing the file waits for, so it never promises a box that stays shut. The
    /// phone passes `inVoice: false`, because its `step` does not wait on voice.
    public static func waitReason(isResponding: Bool, inVoice: Bool, consentPending: Bool) -> WaitReason? {
        if inVoice { return .voice }
        if consentPending { return .consent }
        return isResponding ? .reply : nil
    }

    /// The hint over the composer while shared files wait, in plain words (Kev is dyslexic: short sentences, no
    /// jargon), or nil when nothing is waiting. It only tells: staging is still `step`'s, and nothing is sent.
    public static func waitingHint(count: Int, reason: WaitReason?) -> String? {
        guard count > 0, let reason else { return nil }
        // One file has its own sentence rather than the catalog's plural "one" form: CI's older SwiftPM doesn't
        // compile a package catalog's plural variations, so `count == 1` read "1 files are waiting" there (#903).
        // The plural keys keep their variations for languages with more forms.
        let one = count == 1
        switch reason {
        case .reply:
            return one
                ? String(
                    localized: "1 file is waiting. It goes in the box when this reply ends.",
                    bundle: .module,
                    comment: """
                    Hint over the chat's message box: a file shared to M1K3 from another app waits until \
                    M1K3 finishes its answer. 'the box' is the message box where you type.
                    """
                )
                : String(
                    localized: "\(count) files are waiting. They go in the box when this reply ends.",
                    bundle: .module,
                    comment: """
                    Hint over the chat's message box: files shared to M1K3 from another app wait until \
                    M1K3 finishes its answer. 'the box' is the message box where you type. Plural by count.
                    """
                )
        case .voice:
            return one
                ? String(
                    localized: "1 file is waiting. It goes in the box when you leave voice.",
                    bundle: .module,
                    comment: """
                    Hint over the chat's message box: a file shared to M1K3 waits until the person leaves \
                    voice mode. 'the box' is the message box where you type.
                    """
                )
                : String(
                    localized: "\(count) files are waiting. They go in the box when you leave voice.",
                    bundle: .module,
                    comment: """
                    Hint over the chat's message box: files shared to M1K3 wait until the person leaves \
                    voice mode. 'the box' is the message box where you type. Plural by count.
                    """
                )
        case .consent:
            return one
                ? String(
                    localized: "1 file is waiting. It goes in the box when you answer the Private Cloud question.",
                    bundle: .module,
                    comment: """
                    Hint over the chat's message box: a file shared to M1K3 waits until the person answers the \
                    sheet asking whether to send this message to Private Cloud Compute. 'the box' is the message \
                    box where you type.
                    """
                )
                : String(
                    localized: "\(count) files are waiting. They go in the box when you answer the Private Cloud question.",
                    bundle: .module,
                    comment: """
                    Hint over the chat's message box: files shared to M1K3 wait until the person answers the \
                    sheet asking whether to send this message to Private Cloud Compute. 'the box' is the message \
                    box where you type. Plural by count.
                    """
                )
        }
    }

    /// The Mac's held queue: the files among `incoming` (Launch Services' Open With, a drop on the Dock icon,
    /// `open -a M1K3 file`), appended in order to those already `held`, each once, however its path is spelled.
    /// Anything that isn't a file (a web URL, an `m1k3://` link) is dropped: the Mac registers no URL scheme.
    public static func admit(_ incoming: [URL], holding held: [URL]) -> [URL] {
        var seen = Set(held.map(components))
        var queue = held
        for url in incoming {
            guard case let .file(file) = classify(url), seen.insert(components(file)).inserted else { continue }
            queue.append(file)
        }
        return queue
    }

    /// iOS copies a file opened in another app into `Documents/Inbox` (the plist opts out of opening in place).
    /// Once its text or image is staged, that copy is ours to delete: nothing of the user's lingers there.
    public static func isSystemInboxCopy(_ url: URL, documents: URL) -> Bool {
        let inbox = components(documents.appending(path: "Inbox"))
        let path = components(url)
        return path.count > inbox.count && Array(path.prefix(inbox.count)) == inbox
    }

    /// Inbox items to sweep: everything not still waiting to be staged. The shell runs this when the app goes to
    /// the background, never while staging: a batch AirDrop copies every file into Inbox before each one's URL
    /// arrives, and a copy keeps its source's dates, so no age test can tell a sibling in flight from a leftover.
    /// By the time the app leaves the screen every URL of the batch has arrived (#895 second pass).
    public static func inboxLeftovers(_ contents: [URL], waiting: [URL]) -> [URL] {
        let keep = Set(waiting.map(components))
        return contents.filter { !keep.contains(components($0)) }
    }

    /// Path components with `..` folded and iOS's `/private/var` read as `/var` (the system hands a file over
    /// under one, `URL.documentsDirectory` names the other), without touching the disk.
    private static func components(_ url: URL) -> [String] {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count > 2, parts[0] == "/", parts[1] == "private", parts[2] == "var" {
            return ["/"] + parts.dropFirst(2)
        }
        return parts
    }

    /// The UTIs the iPhone plist registers under CFBundleDocumentTypes: the ＋ picker's file types. Images and
    /// PDFs are not registered in slice 1 (PDFs go through Documents on the phone today; that decision is owed).
    public static var registeredTypeIdentifiers: [String] {
        AttachmentRouting.fileTypes.map(\.identifier)
    }
}
