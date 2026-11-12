//
//  AudioPlayerStart.swift
//  M1K3Voice
//
//  Starting an AVAudioPlayerNode can raise an Objective-C exception that Swift
//  cannot catch: "player did not see an IO cycle" when the engine is not really
//  running. `engine.isRunning` does not rule it out (the engine can read running
//  with its IO stopped), and on the phone it is a race with the background exit:
//  the app was aborted when it left for the background just as a spoken sentence
//  was about to start (iPhone 17 Pro drill, 2026-11-11: 2 of 10 runs).
//
//  So the start goes through the ObjC shim, and a refused start is a value the
//  renderer acts on: stop the utterance and rebuild the engine for the next one.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.75, Prior: none (new file).
//  Open: the exception itself is only reachable on a device; the catch is pinned
//  with another NSException under `swift test`.
//

import AVFoundation
import M1K3ObjCTry

enum AudioPlayerStart {
    /// Start the player. Nil when it started; otherwise why the framework refused.
    static func play(_ player: AVAudioPlayerNode) -> String? {
        attempt { player.play() }
    }

    /// The catch itself, over any single framework call (pinned in tests with a plain NSException).
    static func attempt(_ call: () -> Void) -> String? {
        M1K3TryObjC(call)
    }
}
