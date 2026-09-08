//
//  SpeechHighlight.swift
//  M1K3
//
//  Observable word-highlight state for the karaoke reading view: which
//  utterance is being spoken, its timeline (when the backend can provide one),
//  and the word currently being heard. Fed by the SwappableSpeechProvider
//  word-timing callbacks (AppEnvironment.wireSpeechCallbacks); cleared when
//  speech ends. On the plain Built-in tier there is no timeline — only live
//  word ranges — so views must treat `timeline` as optional.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.85 (thin observable
//  state over the tested timing seam). Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-08 — `narrator` rides with the utterance so the HUD can name who is
//  talking (M1K3 vs a visiting MCP client). Confidence now 0.85.
//

import Foundation
import M1K3Voice
import Observation

@MainActor
@Observable
final class SpeechHighlight {
    /// The exact string being spoken — when a timeline exists this is
    /// `timeline.text`, and any highlighting view must render THIS string.
    private(set) var utteranceText: String?
    /// Full word timing, when the backend provides it (Kokoro chunks grow it;
    /// the Apple offline render sets it once; plain Built-in never does).
    private(set) var timeline: SpokenWordTimeline?
    /// UTF-16 range (into `utteranceText`) of the word currently being heard.
    private(set) var currentWordRange: Range<Int>?
    /// Who authored the utterance — M1K3, or a visiting MCP client by name.
    /// The notch HUD captions from this (hit list 2026-09-08, item 2).
    private(set) var narrator: Narrator = .m1k3

    var isActive: Bool {
        utteranceText != nil
    }

    /// A new utterance is about to be spoken.
    func beginUtterance(text: String, narrator: Narrator = .m1k3) {
        utteranceText = text
        self.narrator = narrator
        timeline = nil
        currentWordRange = nil
    }

    func apply(timeline: SpokenWordTimeline) {
        self.timeline = timeline
        utteranceText = timeline.text
    }

    func wordSpoken(_ range: Range<Int>) {
        currentWordRange = range
    }

    func clear() {
        utteranceText = nil
        timeline = nil
        currentWordRange = nil
    }
}
