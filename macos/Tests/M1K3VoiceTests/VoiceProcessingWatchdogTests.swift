import M1K3Voice
import Testing

/// Pins the starve check for Mac voice processing. Measured 2026-10-17 (macOS
/// 27.0): a healthy VPIO tap delivers ~10 buffers a second from start; a starved
/// one delivers none at all, ever (7-channel format, zero buffers over 3 s), so
/// "no buffer" is the signal. Two looks a deadline apart, and another after a
/// route-change reinstall (which restarts the count), so a slow or reconfigured
/// start is never written off for the engagement (#review, 2026-10-17).
struct VoiceProcessingWatchdogTests {
    @Test("any buffer by a check means echo cancellation is live")
    func anyBufferIsLive() {
        #expect(VoiceProcessingWatchdog.decision(buffersSeen: 1, check: 1, reinstalledSinceLastCheck: false) == .live)
        #expect(VoiceProcessingWatchdog.decision(buffersSeen: 6, check: 2, reinstalledSinceLastCheck: true) == .live)
    }

    @Test("nothing at the first check looks again: a cold VPIO under load gets a second deadline")
    func firstSilentCheckRechecks() {
        #expect(VoiceProcessingWatchdog.decision(buffersSeen: 0, check: 1, reinstalledSinceLastCheck: false) == .recheck)
    }

    @Test("nothing at the second check, with the same tap, is a starve: back voice processing out")
    func secondSilentCheckStarves() {
        #expect(VoiceProcessingWatchdog.decision(buffersSeen: 0, check: 2, reinstalledSinceLastCheck: false) == .starved)
    }

    @Test("a route-change reinstall since the last check earns another look (its counter restarted), up to the cap")
    func reinstallEarnsARecheckUpToTheCap() {
        #expect(VoiceProcessingWatchdog.decision(buffersSeen: 0, check: 2, reinstalledSinceLastCheck: true) == .recheck)
        #expect(VoiceProcessingWatchdog.decision(
            buffersSeen: 0, check: VoiceProcessingWatchdog.maxChecks, reinstalledSinceLastCheck: true
        ) == .starved)
    }

    @Test("the deadline leaves a healthy tap several buffers of slack (~100 ms each) and stays well under a second")
    func deadlineHasSlack() {
        #expect(VoiceProcessingWatchdog.deadline >= .milliseconds(400))
        #expect(VoiceProcessingWatchdog.deadline <= .milliseconds(800))
    }

    @Test("the watchdog runs on the Mac only: iOS voice processing is device-verified and has no plain fallback")
    func macOnly() {
        #expect(VoiceProcessingWatchdog.applies(platform: .mac))
        #expect(!VoiceProcessingWatchdog.applies(platform: .mobile))
    }

    @Test("a reinstall after the watchdog has finished re-arms it, so echoCancellationLive comes back (#640)")
    func reinstallAfterTheWatchdogRearmsIt() {
        // A mid-listen route change clears the live flag; with no look pending nothing would set it again.
        #expect(VoiceProcessingWatchdog.rearmsAfterReinstall(voiceProcessing: true, lookPending: false))
        // A look already pending sees the reinstall itself (reinstalledSinceLastCheck): a second chain would double-look.
        #expect(!VoiceProcessingWatchdog.rearmsAfterReinstall(voiceProcessing: true, lookPending: true))
        // A plain tap has no starve to watch for.
        #expect(!VoiceProcessingWatchdog.rearmsAfterReinstall(voiceProcessing: false, lookPending: false))
    }
}
