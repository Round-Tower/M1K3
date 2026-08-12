//
//  SpeechEntryGateTests.swift
//  M1K3VoiceTests
//
//  Pins the no-overlap contract of EffectfulSpeechProvider's SpeechEntryGate — the
//  serial gate that closed the #52 review residual. Before it, two speak() calls
//  that BOTH saw an idle provider started two overlapping renders on the single
//  AVSpeechSynthesizer, leaking the loser's SynthBox continuation. The gate makes
//  render bodies run strictly one-at-a-time; these are pure structural tests (no
//  audio device, no AVFoundation), so they run on CI. The live barge-in WIRING —
//  that a superseded render's box is still the delegate when its didCancel arrives
//  — stays verify-by-launch, per the provider's rule.
//
//  Signed: Kev + Claude, 2026-07-19, Confidence 0.85, Prior: Unknown
//

@testable import M1K3Voice
import Testing

struct SpeechEntryGateTests {
    /// Tracks how many gate bodies are executing at once and how many ran in total.
    private actor Concurrency {
        private(set) var current = 0
        private(set) var maxObserved = 0
        private(set) var completed = 0

        func enter() {
            current += 1
            maxObserved = max(maxObserved, current)
        }

        func leave() {
            current -= 1
            completed += 1
        }
    }

    @Test("run executes bodies strictly one-at-a-time even when entrants pile in concurrently")
    func neverOverlaps() async {
        let gate = SpeechEntryGate()
        let tracker = Concurrency()

        // Fan a batch of entrants at the gate at once. Each body yields several
        // times mid-flight so that, WITHOUT serialisation, two would interleave and
        // push `current` above 1 — exactly the overlapping-render race.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 12 {
                group.addTask {
                    await gate.run {
                        await tracker.enter()
                        for _ in 0 ..< 5 {
                            await Task.yield()
                        }
                        await tracker.leave()
                    }
                }
            }
        }

        #expect(await tracker.maxObserved == 1) // never two bodies at once
        #expect(await tracker.completed == 12) // and every entrant ran
    }

    @Test("the gate is reusable once drained — a later run still executes")
    func reusableAfterDrain() async {
        let gate = SpeechEntryGate()
        let tracker = Concurrency()

        await gate.run { await tracker.enter(); await tracker.leave() }
        // Second, independent use after the first fully completed (tail dropped).
        await gate.run { await tracker.enter(); await tracker.leave() }

        #expect(await tracker.completed == 2)
        #expect(await tracker.maxObserved == 1)
    }

    /// Reference box so the render closure (non-Sendable, non-escaping) can record
    /// whether it ran without a cross-actor mutable capture.
    private final class RanFlag: @unchecked Sendable { var value = false }

    @Test("a superseded entry skips its render closure — so speak(stream:) won't spurious-fallback on barge-in")
    func supersededEntrySkipsRender() async {
        // The provider-level guard the streaming fix relies on: when a newer speak()
        // supersedes a queued one, runRender must bail WITHOUT running the render —
        // that's what lets speak(stream:)'s `true`-seeded outcome survive (so the
        // abandoned utterance doesn't report "nothing spoken" and trigger a stale
        // Apple-voice fallback that stop()s the newer render — the #52 barge-in bug).
        let provider = EffectfulSpeechProvider()

        let stale = await provider.claimEntry() // generation N
        _ = await provider.claimEntry() // generation N+1 supersedes it

        let ranStale = RanFlag()
        await provider.runRender(stale) { ranStale.value = true }
        #expect(ranStale.value == false) // superseded → closure never runs

        // The current (latest) generation still renders normally.
        let current = await provider.claimEntry()
        let ranCurrent = RanFlag()
        await provider.runRender(current) { ranCurrent.value = true }
        #expect(ranCurrent.value == true)
    }

    /// The other way to be stale, and the one that used to sail straight through:
    /// nothing superseded this entry, the user just said stop while it was queued
    /// behind another render. `stop()` only ever interrupted the render already
    /// running, so the one waiting its turn spoke afterwards — you stopped M1K3 and
    /// M1K3 answered you (Kev, 2026-08-12: "it goes right to the end").
    ///
    /// Headless: `claimEntry`/`runRender` are pure bookkeeping and a fresh provider
    /// is idle, so nothing here touches an audio device.
    @Test("a render claimed before a stop() does not run after it")
    func stopCancelsAQueuedRender() async {
        let provider = EffectfulSpeechProvider()

        let queued = await provider.claimEntry()
        await provider.stop() // the user's stop lands while `queued` waits its turn

        let ranQueued = RanFlag()
        await provider.runRender(queued) { ranQueued.value = true }
        #expect(ranQueued.value == false)

        // ...and the provider is not poisoned: the NEXT thing asked for still speaks.
        // (A stop epoch compared with `>=` instead of `==`, or one never re-sampled,
        // would mute everything from here on — the failure mode that would be much
        // worse than the bug.)
        let afterwards = await provider.claimEntry()
        let ranAfterwards = RanFlag()
        await provider.runRender(afterwards) { ranAfterwards.value = true }
        #expect(ranAfterwards.value == true)
    }

    /// A barge-in — speak while already speaking — internally calls `stop()` to
    /// interrupt the predecessor. That stop must not read as a reason to cancel the
    /// utterance that *caused* it, or every interruption would silence both sides.
    @Test("the stop a barge-in fires does not cancel the barge-in itself")
    func bargeInSurvivesItsOwnStop() async {
        let provider = EffectfulSpeechProvider()

        let first = await provider.claimEntry()
        let ranFirst = RanFlag()
        await provider.runRender(first) { ranFirst.value = true }
        #expect(ranFirst.value == true)

        // Second claim on a provider that just rendered: whatever housekeeping stop
        // this triggers, the claimant's own entry must remain current.
        let second = await provider.claimEntry()
        let ranSecond = RanFlag()
        await provider.runRender(second) { ranSecond.value = true }
        #expect(ranSecond.value == true)
    }

    @Test("truly-concurrent claimEntry calls get distinct, gap-free generations")
    func concurrentClaimEntryGenerationsAreDistinct() async {
        // The bump must be atomic under real task contention — no two callers may
        // share a generation (which would let a stale entry masquerade as current)
        // and none may be lost. A fresh provider is idle, so no claim triggers stop().
        let provider = EffectfulSpeechProvider()
        let count = 64

        let generations = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< count {
                group.addTask { await provider.claimEntry().generation }
            }
            var collected: [Int] = []
            for await generation in group {
                collected.append(generation)
            }
            return collected
        }

        #expect(generations.count == count)
        #expect(Set(generations).count == count) // all distinct — no lost/duplicated bumps
        #expect(Set(generations) == Set(1 ... count)) // gap-free 1...count
    }
}
