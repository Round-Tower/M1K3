//
//  AudioInterruptionPolicy.swift
//  M1K3Voice
//
//  What voice mode does when the OS takes the audio session away — a phone
//  call or Siri (interruption), headphones pulled (route loss), the media
//  server restarting. Pure: an event and the loop's state in, one action out.
//  The app layer (AppCore+Voice on iOS) turns AVAudioSession notifications
//  into `Event`s and applies the `Action` to the VoiceLoopController.
//
//  Rules (all test-pinned):
//  • An interruption beginning PAUSES any active state — never keep listening
//    or speaking through a call.
//  • An interruption ending never resumes the mic unasked, even when the OS
//    says it may: the user taps to continue. A phone that starts listening on
//    its own when a call ends is a surprise, and surprises are what a
//    hands-free mic must never do.
//  • Headphones pulled pauses any active state — an answer that jumps to the
//    loudspeaker is the classic failure Apple's own guidance names.
//  • Other route changes (headphones plugged in, a category change) are left
//    alone; the engine follows the new route on its next listen.
//  • A media-services reset ends the mode outright: the session underneath is
//    gone and every engine on it must be rebuilt from scratch.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-03, Confidence 0.85 (pure table,
//  pinned; the notification mapping in the app layer is verify-by-launch on a
//  real phone — the simulator cannot take a call). Prior: none (new file).
//

import Foundation

public enum AudioInterruptionPolicy {
    public enum RouteChangeReason: Equatable, Sendable {
        /// The device in use went away (headphones unplugged, Bluetooth dropped).
        case oldDeviceUnavailable
        case newDeviceAvailable
        case other
    }

    public enum Event: Equatable, Sendable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(reason: RouteChangeReason)
        case mediaServicesReset
    }

    public enum Action: Equatable, Sendable {
        case none
        /// VoiceLoopController.pause(): stop whichever direction is live, park.
        case pause
        /// Leave voice mode entirely.
        case exit
    }

    public static func action(for event: Event, in state: VoiceLoopState) -> Action {
        switch event {
        case .interruptionBegan:
            return isActive(state) ? .pause : .none
        case .interruptionEnded:
            return .none
        case let .routeChanged(reason):
            return reason == .oldDeviceUnavailable && isActive(state) ? .pause : .none
        case .mediaServicesReset:
            return state == .ended ? .none : .exit
        }
    }

    private static func isActive(_ state: VoiceLoopState) -> Bool {
        switch state {
        case .listening, .awaitingAnswer, .speaking: true
        case .idle, .ended: false
        }
    }
}
