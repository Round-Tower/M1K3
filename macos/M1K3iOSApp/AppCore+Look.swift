//
//  AppCore+Look.swift
//  M1K3iOS / M1K3visionOS
//
//  The look, wired (#768): a frame off `LookCamera`, kept in the attachment
//  store, asked of the on-device brain through `ChatSession.look`. Two ways in:
//  the Look screen off the composer (`look`), and voice mode (`voiceLook`),
//  where an open eye makes every turn a look and a spoken ask with the eye
//  closed takes one glance and closes it again.
//
//  The frame's whole journey is camera → this container → the on-device brain.
//  `looker` is the local slot, the turn runs no tools, and the answer is kept
//  out of distilled memory (ChatSession.look). What a look leaves behind is the
//  chat turn: the question, the answer and the frame as that message's
//  attachment, deleted with the conversation like any attached photo.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.7, Prior: none (new file)
//  Context: Kev, 2026-11-09: "Let's implement the vision on this research pal,
//  and make it easily accessible via chat, and voice interfaces".
//  Open: a typed follow-up after a look is an ordinary send, and that send can
//  still pick web_search for its words (2026-11-09 spike, third turn). With the
//  eye open in voice mode a question that is not about the view is still
//  answered as a look. Both are Kev's calls on #768.
//

import Foundation
import M1K3Chat
import M1K3Inference
import M1K3Screengrab

extension AppCore {
    /// Whether the eye is offered: the brain that answers sees and answers on
    /// this device, and there is a camera. Never under the screengrab harness.
    var canLook: Bool {
        imagesAccepted && LookCamera.deviceHasCamera && !ScreengrabHarness.current.isActive
    }

    /// One look from the Look screen: a fresh frame and the question. False
    /// when no turn ran (no frame, or a turn was already streaming).
    @discardableResult
    func look(_ question: String) async -> Bool {
        guard isReady, canLook, !chat.isResponding else { return false }
        guard let frame = await lookFrame() else { return false }
        avatar.setActivity(.thinking)
        beginAutoSpeakSession() // before the turn: it pins this turn's answer
        guard await chat.look(question, frame: frame, looker: looker) else {
            AttachmentStore.discard([frame])
            cancelAutoSpeak()
            avatar.resetToIdle()
            return false
        }
        settleTypedTurn()
        return true
    }

    /// One voice turn through the eyes. False means it was not a look (or no
    /// frame came), and the caller sends the words as an ordinary turn.
    func voiceLook(_ question: String) async -> Bool {
        let eyesOpen = lookCamera.isOpen
        let able = canLook && isReady && !chat.isResponding
        guard LookIntent.voiceTurnLooks(question, eyesOpen: eyesOpen, canLook: able) else { return false }
        let frame = await lookFrame()
        // A spoken ask with the eye closed is one glance: the camera goes off
        // again as soon as the frame is taken.
        if !eyesOpen { lookCamera.close() }
        guard let frame else { return false }
        guard await chat.look(question, frame: frame, looker: looker) else {
            AttachmentStore.discard([frame])
            return false
        }
        return true
    }

    /// The eye toggle in voice mode. A refused camera says so in the caption.
    func toggleEyes() async {
        if lookCamera.isOpen {
            lookCamera.close()
            return
        }
        guard canLook else { return }
        if await !lookCamera.open(), lookCamera.state == .denied || lookCamera.state == .restricted {
            voicePauseNote = "Camera access is off for M1K3. You can allow it in Settings."
        }
    }

    /// The camera's newest frame, stored. Nil when the camera will not open or
    /// the bytes will not write.
    private func lookFrame() async -> ImageAttachment? {
        guard await lookCamera.open(), let jpeg = await lookCamera.frame() else { return nil }
        return try? Self.attachmentStore.store(data: jpeg, fileExtension: "jpg")
    }
}
