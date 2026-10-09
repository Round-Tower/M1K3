@testable import M1K3Avatar
import Testing

/// The drifting orbs (AudioCaptureBackdrop) are an "I'm capturing audio" cue.
/// Voice mode used to count as one (2026-06-11), but the full-window hero has
/// covered the orbs with an opaque floor since 2026-06-26 — so they ticked a
/// 30 fps TimelineView during MLX decode for nobody. Now that the hero sits on
/// the window glass they would show again; voice alone raises none.
struct AmbientBackdropPolicyTests {
    @Test("nothing capturing: no orbs (voice mode alone is not a cue)")
    func quietRaisesNoOrbs() {
        #expect(!AmbientBackdropPolicy.shows(isListening: false, isRecording: false))
    }

    @Test("chat dictation raises the orbs")
    func listeningRaisesOrbs() {
        #expect(AmbientBackdropPolicy.shows(isListening: true, isRecording: false))
    }

    @Test("a call recording raises the orbs, wherever you are in the app")
    func recordingRaisesOrbs() {
        #expect(AmbientBackdropPolicy.shows(isListening: false, isRecording: true))
        #expect(AmbientBackdropPolicy.shows(isListening: true, isRecording: true))
    }
}
