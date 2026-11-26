//
//  AppCore+VoiceBehindLock.swift
//  M1K3iOS
//
//  A voice conversation that keeps going when the phone locks (VoiceBehindLockPolicy has the rules and why).
//  The shell half:
//
//  - `.inactive` from `.active` with a conversation to keep: the Live Activity face goes up. ActivityKit refuses a
//    start from the background, so this is the last chance; a return without a lock (Control Center) ends it.
//  - `.background`: voice mode is NOT left. The mic engine keeps running between listens (iOS refuses to start one
//    in the background), the M1K3 voice (Kokoro, GPU) hands over to the system voice, the camera closes, and the
//    slot points at the brain that answers behind the lock. A minute of silence ends the conversation.
//  - `.active`: everything comes back. The card ends, and `warmForForeground` re-warms the chosen brain. A lock
//    goes inactive → active → background, so an `.active` that was never behind the lock ends the card only if
//    the app is still in front a second later (the first phone run lost its card to that blip).
//
//  Salvaged from the throwaway spike (spike/bg-voice, 2026-11-16/17), without its file log, launch flags or the
//  Kokoro-on-CPU bench (inconclusive, owed a re-run).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-26, Confidence 0.7 (the rules are tested in VoiceBehindLockPolicyTests;
//  this wiring is the phone run: lock mid-conversation, unpaired and paired). Prior: the spike's
//  AppCore+BGVoiceSpike.swift and SpikeVoiceCard.swift (Kev + claude-opus-5.5, 2026-11-16/17).
//

import Foundation
import M1K3LiveActivity
import M1K3Voice
import os
#if os(iOS)
    import UIKit
#endif
#if os(iOS) && canImport(ActivityKit)
    import ActivityKit
#endif

/// The conversation's life behind the lock: silence, the running turn, and the Lock Screen face. Main-actor
/// state, owned by AppCore.
@MainActor
final class VoiceBehindLock {
    /// The Settings switch (Kev, 2026-11-26: on by default).
    nonisolated static let switchKey = "voice.keepsGoingBehindLock"

    static var switchOn: Bool {
        UserDefaults.standard.object(forKey: switchKey) as? Bool ?? VoiceBehindLockPolicy.onByDefault
    }

    nonisolated static let log = Logger(subsystem: "app.m1k3", category: "voice")

    /// Set while the conversation is behind the lock: the brain answering there.
    private(set) var brain: VoiceBehindLockPolicy.Brain?
    /// Bumped by every enter and leave, so a slot switch still waiting on the shed can tell its lock is over.
    private(set) var epoch = 0
    /// The slot switch for this lock (`pointSlotBehindLock`); a voice turn waits for it, the return cancels it.
    var pointTask: Task<Void, Never>?
    private var lastSpeech = ContinuousClock.now
    private var turnRunning = false
    /// From the first sentence's start to the last one's end: an answer still being spoken is not silence.
    private var speaking = false
    private var silenceWatch: Task<Void, Never>?
    private let card = VoiceBehindLockCard()

    var isBehindLock: Bool {
        brain != nil
    }

    // MARK: The loop's beats (any time: the card moves only while it is up)

    func listening() {
        card.show(.listening)
    }

    func heardSpeech() {
        lastSpeech = .now
    }

    func turnSent() {
        turnRunning = true
        lastSpeech = .now
        card.show(.thinking)
    }

    func speakingStarted() {
        speaking = true
        lastSpeech = .now
        card.show(.speaking)
    }

    func speakingEnded() {
        speaking = false
        lastSpeech = .now
    }

    /// Wait for this lock's slot switch to land (immediate in front, or once it has).
    func slotPointed() async {
        await pointTask?.value
    }

    func turnEnded() {
        turnRunning = false
        lastSpeech = .now // silence counts again from the end of the answer
    }

    // MARK: Entering and leaving

    func showCard() {
        card.start()
    }

    /// A return to the front that never went behind the lock: the lock's own `.active` blip comes just before the
    /// background, so wait a moment and end the card only if the app is really still in front.
    func endCardIfStillInFront() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !isBehindLock, Self.appIsInFront else { return }
            card.end()
        }
    }

    private static var appIsInFront: Bool {
        #if os(iOS)
            UIApplication.shared.applicationState == .active
        #else
            true
        #endif
    }

    /// The conversation ended behind the lock (silence): the face comes down, and the brain stays recorded so
    /// the return still undoes the slot.
    func endCard() {
        card.end()
    }

    func entered(_ brain: VoiceBehindLockPolicy.Brain, onSilence: @escaping @MainActor () -> Void) -> Int {
        self.brain = brain
        epoch += 1
        lastSpeech = .now
        silenceWatch?.cancel()
        silenceWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, isBehindLock else { return }
                let busy = turnRunning || speaking
                if VoiceBehindLockPolicy.endsForSilence(silentFor: lastSpeech.duration(to: .now), turnRunning: busy) {
                    Self.log.notice("voice behind the lock: a minute of silence, conversation ended")
                    onSilence()
                    return
                }
            }
        }
        Self.log.notice("voice behind the lock: kept, brain \(String(describing: brain), privacy: .public)")
        return epoch
    }

    /// Back in the app, or the conversation over. Returns the brain the lock had pointed the slot at, to undo.
    @discardableResult
    func left() -> VoiceBehindLockPolicy.Brain? {
        let was = brain
        brain = nil
        epoch += 1
        pointTask?.cancel()
        pointTask = nil
        silenceWatch?.cancel()
        silenceWatch = nil
        card.end()
        return was
    }
}

extension AppCore {
    /// The brain a conversation would keep behind the lock right now, or nil to leave voice mode as the app goes.
    var voiceBehindLockBrain: VoiceBehindLockPolicy.Brain? {
        #if os(iOS)
            VoiceBehindLockPolicy.brain(
                switchOn: VoiceBehindLock.switchOn, voiceModeActive: isVoiceModeActive,
                chosenRunsOnThisGPU: chosenBrainRunsOnThisGPU, homePaired: homeBrainPaired,
                miniAvailable: miniAvailableNow
            )
        #else
            nil // visionOS: no Lock Screen to keep talking behind
        #endif
    }

    /// `.inactive` from `.active`: put the face on the Lock Screen while ActivityKit still allows a start.
    func voiceBehindLockGoingInactive() {
        guard voiceBehindLockBrain != nil else { return }
        voiceBehindLock.showCard()
    }

    /// `.background`, AFTER `stopForBackground` and `releaseForBackground`, for a conversation that stays.
    func enterVoiceBehindLock(_ brain: VoiceBehindLockPolicy.Brain) {
        let mic = transcriber as? AppleSpeechTranscriber
        mic?.keepsMicRunningBetweenListens = true
        // The room classifier (SoundAnalysis) runs on the GPU: behind the lock every listen's analysis failed with
        // "Insufficient Permission (to submit GPU work from background)" (phone run, 2026-11-26). Off there; the
        // turns just carry no room line.
        mic?.hearsRoom = false
        // Kokoro is MLX on Metal: never behind the lock. The swap is first, so nothing new reaches it.
        speech.setProvider(builtinSpeech)
        let neural = kokoro
        Task { await neural.stop() }
        lookCamera.close() // the camera can't run behind the lock
        let epoch = voiceBehindLock.entered(brain) { [weak self] in
            self?.voiceBehindLock.endCard()
            self?.exitVoiceMode()
        }
        voiceBehindLock.pointTask = Task { [weak self] in await self?.pointSlotBehindLock(brain, epoch: epoch) }
    }

    /// `.active`, BEFORE `warmForForeground`: the card ends, and the slot, the mic and the voice come back.
    func voiceBehindLockReturning() {
        // Never behind the lock: a Control Center pull, or the lock's own blip (iOS goes inactive → active →
        // background as the phone locks; the phone run on 2026-11-26 lost its card to that `.active`). The card
        // comes down only if the app is still in front a moment later.
        guard voiceBehindLock.isBehindLock else {
            voiceBehindLock.endCardIfStillInFront()
            return
        }
        guard let brain = voiceBehindLock.left() else { return }
        restoreSlotAfterLock(brain)
        let mic = transcriber as? AppleSpeechTranscriber
        mic?.keepsMicRunningBetweenListens = false
        mic?.hearsRoom = isVoiceModeActive // back on for a conversation still going (enterVoiceMode's setting)
        // A loop parked between listens (a failed listen, an interruption) holds no tap, so no teardown will come
        // to stop the engine the lock kept running: release it now. A live listen keeps its hardware ("kept").
        mic?.releaseAudioHardware()
        if selectedVoiceTier == .m1k3Voice, case .ready = voiceLoad {
            speech.setProvider(kokoro)
        }
    }

    /// An interruption that ended behind the lock: nobody can tap the face, so the listen picks itself back up.
    func voiceBehindLockInterruptionEnded(shouldResume: Bool) {
        guard voiceBehindLock.isBehindLock, let loop = voiceLoop,
              VoiceBehindLockPolicy.resumesAfterInterruption(shouldResume: shouldResume, loop: loop.state)
        else { return }
        resumeVoiceListening()
    }
}

/// The Lock Screen face for a conversation behind the lock: the turn card's attributes and widget, with the voice
/// phases. Voice turns never drive the turn card (only typed, read and look turns do), and this card is addressed
/// by its own id, so the two never touch each other's card. Phase words only, never what was said.
@MainActor
final class VoiceBehindLockCard {
    private var cardID: String?
    private var lastPhase: TurnActivityPhase?

    func start() {
        #if os(iOS) && canImport(ActivityKit)
            guard cardID == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let state = TurnActivityState(phase: .listening)
            do {
                let card = try Activity.request(
                    attributes: TurnActivityAttributes(),
                    content: ActivityContent(state: state, staleDate: TurnActivityStaleness.staleDate(for: state, now: .now)),
                    pushType: nil
                )
                cardID = card.id
                lastPhase = .listening
                VoiceBehindLock.log.notice("voice card up: \(String(describing: card.activityState), privacy: .public)")
            } catch {
                VoiceBehindLock.log.error("voice card refused: \(error.localizedDescription, privacy: .public)")
            }
        #endif
    }

    /// Move the face. A repeat of the same phase sends nothing (a silent listen re-arms every few seconds).
    func show(_ phase: TurnActivityPhase) {
        #if os(iOS) && canImport(ActivityKit)
            guard let cardID, phase != lastPhase else { return }
            lastPhase = phase
            let state = TurnActivityState(phase: phase)
            let content = ActivityContent(state: state, staleDate: TurnActivityStaleness.staleDate(for: state, now: .now))
            Task { await Self.update(cardID, content) }
            VoiceBehindLock.log.notice("voice card phase: \(phase.rawValue, privacy: .public)")
        #endif
    }

    func end() {
        #if os(iOS) && canImport(ActivityKit)
            guard let cardID else { return }
            self.cardID = nil
            lastPhase = nil
            Task { await Self.end(cardID) }
        #endif
    }

    #if os(iOS) && canImport(ActivityKit)
        /// An `Activity` is not Sendable: find the card by id in ActivityKit's own list (as TurnActivityController does).
        private nonisolated static func update(_ id: String, _ content: ActivityContent<TurnActivityState>) async {
            var found = false
            for card in Activity<TurnActivityAttributes>.activities where card.id == id {
                found = true
                await card.update(content)
                // A breadcrumb per update: the card vanished mid-answer on the first phone run, and only
                // ActivityKit's own state can say whether iOS ended it or just hid it.
                VoiceBehindLock.log.notice(
                    "voice card updated: state=\(String(describing: card.activityState), privacy: .public) cards=\(Activity<TurnActivityAttributes>.activities.count, privacy: .public)"
                )
            }
            if !found { VoiceBehindLock.log.notice("voice card gone: ActivityKit no longer lists it") }
        }

        private nonisolated static func end(_ id: String) async {
            for card in Activity<TurnActivityAttributes>.activities where card.id == id {
                await card.end(nil, dismissalPolicy: .immediate)
            }
        }
    #endif
}
