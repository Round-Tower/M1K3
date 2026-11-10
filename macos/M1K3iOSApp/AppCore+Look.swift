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
//  out of distilled memory and out of every later turn's history
//  (ChatSession.look). What a look leaves behind is the chat turn: the
//  question, the answer and the frame as that message's attachment, deleted
//  with the conversation like any attached photo.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.7, Prior: none (new file)
//  Context: Kev, 2026-11-09: "Let's implement the vision on this research pal,
//  and make it easily accessible via chat, and voice interfaces".
//  Open: a typed follow-up after a look is an ordinary send, and that send can
//  still pick web_search for its words (2026-11-09 spike, third turn). With the
//  eye open in voice mode a question that is not about the view is still
//  answered as a look. Both are Kev's calls on #768.
//  Review: Kev + claude-fable-5.2, 2026-11-09 (review fold, before the first
//  push) — a turn that asked for the camera never becomes a send: with no
//  frame it says so (`chat.lookMissed`) instead of falling through to a turn
//  that can pick a tool or answer from memory. A look never opens a camera
//  for a screen or a voice mode that has gone; one look at a time
//  (`isLooking`); the eye toggle reads on-or-opening. And a look is now
//  display-only (ChatSession.look): its words are not replayed to later turns.
//  Confidence 0.6: compile-checked and scan-pinned; untried in the hand.
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
    /// when no answer was asked of a brain. The camera is the screen's: a look
    /// never opens one, so an ask that outlives its screen turns nothing on.
    @discardableResult
    func look(_ question: String) async -> Bool {
        guard isReady, canLook, lookCamera.isOpen, !chat.isResponding, !isLooking else { return false }
        isLooking = true
        defer { isLooking = false }
        guard let frame = await storedFrame() else {
            // The screen closed under the ask: nothing to say to nobody.
            // Still open with no picture: say so where the answer would be.
            if lookCamera.isOpen { await chat.lookMissed(question, saying: LookFailureReply.noFrame) }
            return false
        }
        // Another turn began while the frame was taken: this one stands down
        // before it pins that turn's answer for speech.
        guard !chat.isResponding else {
            AttachmentStore.discard([frame])
            return false
        }
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

    /// One voice turn through the eyes. False means the words were not a look
    /// and the caller sends them as an ordinary turn. True means the turn was
    /// a look and is spent, frame or no frame: words that asked for the camera
    /// never become a send, which could pick a tool or answer as if it had seen.
    func voiceLook(_ question: String) async -> Bool {
        // Voice mode's turns only: one that lands after the mode was left opens no camera.
        guard voiceLoop != nil else { return false }
        let eyesOpen = lookCamera.isOpen
        let eyeWasOn = lookCamera.isOn
        let able = canLook && isReady && !chat.isResponding && !isLooking
        guard LookIntent.voiceTurnLooks(question, eyesOpen: eyesOpen, canLook: able) else { return false }
        isLooking = true
        defer { isLooking = false }

        let opened = await lookCamera.open()
        let frame = opened ? await storedFrame() : nil
        // A spoken ask with the eye closed is one glance: the camera goes off
        // again as soon as the frame is taken.
        if !eyeWasOn { lookCamera.close() }
        guard voiceLoop != nil else {
            // The mode was left mid-glance (its exit closed the camera).
            if let frame { AttachmentStore.discard([frame]) }
            return true
        }
        guard let frame else {
            let refused = lookCamera.state == .denied || lookCamera.state == .restricted
            await chat.lookMissed(question, saying: refused ? LookFailureReply.cameraOff : LookFailureReply.noFrame)
            return true
        }
        if await !chat.look(question, frame: frame, looker: looker) {
            AttachmentStore.discard([frame]) // a turn was already answering: this one is superseded
        }
        return true
    }

    /// The eye toggle in voice mode. A refused camera says so in the caption.
    func toggleEyes() async {
        // On or on its way: a second tap during the permission ask closes.
        if lookCamera.isOn {
            lookCamera.close()
            return
        }
        guard voiceLoop != nil, canLook else { return }
        let opened = await lookCamera.open()
        let refused = lookCamera.state == .denied || lookCamera.state == .restricted
        if !opened, refused, voiceLoop != nil { voicePauseNote = LookFailureReply.cameraOff }
    }

    /// The open camera's newest frame, stored. Nil when no fresh picture came
    /// or the bytes would not write. Never opens the camera.
    private func storedFrame() async -> ImageAttachment? {
        guard let jpeg = await lookCamera.frame() else { return nil }
        return try? Self.attachmentStore.store(data: jpeg, fileExtension: "jpg")
    }
}
