import M1K3Chat
import Testing

/// The phone's "your answer is ready" notification: the pure decisions. The effect (UNUserNotificationCenter)
/// is the app target's.
struct TurnNoticePolicyTests {
    @Test("an answer that lands while the app is away says it is ready; a read says it finished reading")
    func answeredInBackground() {
        #expect(TurnNoticePolicy.notice(for: .answered, kind: .answer, appActive: false) == .answerReady)
        #expect(TurnNoticePolicy.notice(for: .answered, kind: .read, appActive: false) == .readFinished)
    }

    @Test("never while the app is active: the answer is already on screen")
    func silentInForeground() {
        #expect(TurnNoticePolicy.notice(for: .answered, kind: .answer, appActive: true) == nil)
        #expect(TurnNoticePolicy.notice(for: .answered, kind: .read, appActive: true) == nil)
    }

    @Test("a failure, the user's stop and a new chat are not news", arguments: [
        TurnActivityPolicy.Outcome.failed, .stopped, .newChat,
    ])
    func silentForTheRest(outcome: TurnActivityPolicy.Outcome) {
        #expect(TurnNoticePolicy.notice(for: outcome, kind: .answer, appActive: false) == nil)
    }

    @Test("the permission is asked only after a LONG answer finishes in the foreground")
    func asksAtTheRightMoment() {
        let long = TurnNotificationPolicy.longTurnThreshold
        #expect(TurnNoticePolicy.shouldAskPermission(for: .answered, duration: long, appActive: true))
        #expect(!TurnNoticePolicy.shouldAskPermission(for: .answered, duration: long - .milliseconds(1), appActive: true))
        // Never mid-answer, never from the background, never for a turn that did not land.
        #expect(!TurnNoticePolicy.shouldAskPermission(for: .answered, duration: long, appActive: false))
        #expect(!TurnNoticePolicy.shouldAskPermission(for: .failed, duration: long, appActive: true))
        #expect(!TurnNoticePolicy.shouldAskPermission(for: .stopped, duration: long, appActive: true))
    }

    @Test("the words are fixed: no placeholder, so no question, answer or file name can reach them")
    func copyIsGeneric() {
        for notice in [TurnNoticePolicy.Notice.answerReady, .readFinished, .paused] {
            #expect(!notice.title.isEmpty && !notice.body.isEmpty)
            #expect(!notice.title.contains("%") && !notice.body.contains("%"))
            #expect(!notice.title.contains("M1K3")) // the banner already names the app (the Mac's rule)
        }
        #expect(TurnNoticePolicy.Notice.paused.body.contains("Open M1K3"))
    }

    @Test("one identifier and one thread for every turn notice, so a later one replaces the earlier")
    func oneStackedNotice() {
        #expect(TurnNoticePolicy.identifier == "turn.notice")
        #expect(TurnNoticePolicy.threadIdentifier == "turn")
    }
}
