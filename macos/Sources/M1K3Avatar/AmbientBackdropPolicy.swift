//
//  AmbientBackdropPolicy.swift
//  M1K3Avatar
//
//  When the drifting orbs (the Mac's AudioCaptureBackdrop) show: audio capture —
//  chat dictation or a call recording. Voice mode was a cue too (2026-06-11,
//  "keep the ambient backdrop alive through voice-first mode"), but the full-window
//  hero of 2026-06-26 covered them with an opaque gradient, so for months they
//  ticked a 30 fps TimelineView during MLX decode that nobody saw. With the hero on
//  the window glass (2026-10-09) they would show again, over the thinking rain and
//  the face — so voice mode is no longer a cue. The hero is its own ambience.
//
//  Pure (plain Bools; no SwiftUI) so ContentView's predicate has a test.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.85 (the orbs were
//  invisible in voice mode by construction; what they cost is measured at 30 fps).
//  Prior: Kev + claude-opus-4-8 (the 2026-06-11 predicate in ContentView).
//

public enum AmbientBackdropPolicy {
    /// Show the orbs while the mic is live for dictation or a call is recording.
    /// Voice mode contributes nothing: its hero fills the window.
    public static func shows(isListening: Bool, isRecording: Bool) -> Bool {
        isListening || isRecording
    }
}
