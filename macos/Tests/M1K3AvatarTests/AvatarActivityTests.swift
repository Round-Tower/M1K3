import M1K3Avatar
import Testing

struct AvatarActivityTests {
    @Test("all 6 cases exist")
    func allCases() {
        #expect(AvatarActivity.allCases.count == 6)
    }

    @Test("isActive is false for idle and error")
    func isActiveIdle() {
        #expect(!AvatarActivity.idle.isActive)
        #expect(!AvatarActivity.error.isActive)
    }

    @Test("isActive is true for engaged states")
    func isActiveEngaged() {
        #expect(AvatarActivity.listening.isActive)
        #expect(AvatarActivity.thinking.isActive)
        #expect(AvatarActivity.generating.isActive)
        #expect(AvatarActivity.speaking.isActive)
    }

    @Test("displayName is non-empty for every case")
    func displayNames() {
        for activity in AvatarActivity.allCases {
            #expect(!activity.displayName.isEmpty)
        }
    }

    @Test("accessibilityLabel names M1K3 and the activity, without the ellipsis VoiceOver would read literally")
    func accessibilityLabelIsSpoken() {
        #expect(AvatarActivity.idle.accessibilityLabel == "M1K3 — Idle")
        #expect(AvatarActivity.thinking.accessibilityLabel == "M1K3 — Thinking")
        #expect(AvatarActivity.speaking.accessibilityLabel == "M1K3 — Speaking")
        #expect(AvatarActivity.listening.accessibilityLabel == "M1K3 — Listening")
        #expect(AvatarActivity.generating.accessibilityLabel == "M1K3 — Generating")
        #expect(AvatarActivity.error.accessibilityLabel == "M1K3 — Error")
        for activity in AvatarActivity.allCases {
            #expect(!activity.accessibilityLabel.contains("…"))
        }
    }
}

struct AvatarActivityStatusLabelTests {
    @Test func recordingWinsOverEveryActivity() {
        // The menu-bar badge showed the red recording dot but said "Idle" —
        // the text must carry the same recording-wins precedence the glyph
        // treatment already pins.
        for activity in AvatarActivity.allCases {
            #expect(activity.statusLabel(isRecording: true) == "Recording")
        }
    }

    @Test func idleReadsAsReadyWhenNotRecording() {
        #expect(AvatarActivity.idle.statusLabel(isRecording: false) == "Ready")
    }

    @Test func activeStatesUseTheirDisplayNameWhenNotRecording() {
        #expect(AvatarActivity.thinking.statusLabel(isRecording: false) == "Thinking…")
        #expect(AvatarActivity.speaking.statusLabel(isRecording: false) == "Speaking…")
    }

    @Test("VoiceOver hears a turn start, the voice states and errors — never generating or idle")
    func voiceOverAnnouncements() {
        #expect(AvatarActivity.thinking.voiceOverAnnouncement(from: .idle) == "M1K3 — Thinking")
        #expect(AvatarActivity.listening.voiceOverAnnouncement(from: .idle) == "M1K3 — Listening")
        #expect(AvatarActivity.speaking.voiceOverAnnouncement(from: .generating) == "M1K3 — Speaking")
        #expect(AvatarActivity.error.voiceOverAnnouncement(from: .thinking) == "M1K3 — Error")
        // The chatty middle and the quiet end of every turn stay silent.
        #expect(AvatarActivity.generating.voiceOverAnnouncement(from: .thinking) == nil)
        #expect(AvatarActivity.idle.voiceOverAnnouncement(from: .generating) == nil)
        // No change, no announcement.
        #expect(AvatarActivity.thinking.voiceOverAnnouncement(from: .thinking) == nil)
    }
}
