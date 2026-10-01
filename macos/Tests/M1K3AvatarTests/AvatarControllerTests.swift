//
//  AvatarControllerTests.swift
//  M1K3AvatarTests
//
//  Signed: Kev + claude-opus-5-5, 2026-10-01, Confidence 0.85, Prior: none (new file)
//

import M1K3Avatar
import Testing

/// An emotion set on purpose (the MCP `speak` emotion) must outlive the
/// activity changes inside the turn; derived emotions must not.
@MainActor
struct AvatarControllerTests {
    @Test("an explicit emotion survives setActivity within the turn")
    func explicitEmotionSurvives() {
        let avatar = AvatarController()
        avatar.setEmotion(.love)
        avatar.setActivity(.speaking)
        #expect(avatar.state == AvatarState(emotion: .love, activity: .speaking))
        avatar.setActivity(.generating)
        #expect(avatar.state.emotion == .love)
    }

    @Test("without an explicit emotion, activity derives one as before")
    func derivedEmotionStillFollowsActivity() {
        let avatar = AvatarController()
        avatar.setActivity(.generating)
        #expect(avatar.state.emotion == .excited)
        avatar.setActivity(.speaking)
        #expect(avatar.state.emotion == .happy)
    }

    @Test("resetToIdle clears the explicit emotion")
    func resetClears() {
        let avatar = AvatarController()
        avatar.setEmotion(.sad)
        avatar.resetToIdle()
        #expect(avatar.state == .idle)
        avatar.setActivity(.speaking)
        #expect(avatar.state.emotion == .happy)
    }

    @Test("the error activity always shows its own distress and drops any explicit emotion")
    func errorWins() {
        let avatar = AvatarController()
        avatar.setEmotion(.happy)
        avatar.setActivity(.error)
        #expect(avatar.state == .error)
        avatar.setActivity(.thinking)
        #expect(avatar.state.emotion == .thinking) // the stale happy didn't come back
    }
}
