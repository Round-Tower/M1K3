//
//  NetworkPathWatchTests.swift
//  M1K3AvatarTests
//
//  The offline signal behind Flight Club: which NWPath statuses count as "offline". Honest by
//  construction: only `.unsatisfied` is offline. `.requiresConnection` (an on-demand VPN, a
//  sleeping cellular radio) and a captive-portal `.satisfied` path lean online, because a
//  missed offline moment is invisible while a false "you're offline" greeting is a lie.
//
//  Signed: Kev + claude-sonnet-5.5, 2026-10-22, Confidence 0.85 (status mapping pinned here; the
//  live monitor is verify-on-device in real Airplane Mode). Prior: none (new file).
//  Review: Kev + claude-sonnet-5.5, 2026-10-22 — review fold: an ordering test over the update stream.
//

@testable import M1K3Avatar
import Network
import Testing

struct NetworkPathWatchTests {
    @Test("only an unsatisfied path is offline")
    func statusMapping() {
        #expect(NetworkPathWatch.isOffline(.satisfied) == false)
        #expect(NetworkPathWatch.isOffline(.requiresConnection) == false)
        #expect(NetworkPathWatch.isOffline(.unsatisfied) == true)
    }

    @Test("the shared watch starts online, so the first frame is never wrongly in flight colours")
    @MainActor
    func startsOnline() {
        let watch = NetworkPathWatch(monitoring: false)
        #expect(watch.isOffline == false)
        watch.apply(offline: true)
        #expect(watch.isOffline == true)
        watch.apply(offline: false)
        #expect(watch.isOffline == false)
    }

    @Test("updates apply in the order they arrive: the last flip wins, however fast they come")
    @MainActor
    func updatesApplyInOrder() async {
        for flips in [[true, false], [false, true], [true, false, true, false], [false, true, false, true]] {
            let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
            let watch = NetworkPathWatch(updates: stream)
            for flip in flips {
                continuation.yield(flip)
            }
            continuation.finish()
            await watch.drained()
            #expect(watch.isOffline == flips.last)
        }
    }
}
