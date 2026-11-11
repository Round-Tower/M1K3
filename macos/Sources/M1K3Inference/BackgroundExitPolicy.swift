//
//  BackgroundExitPolicy.swift
//  M1K3Inference
//
//  What the phone does with an answer that is still being made when the app leaves
//  for the background. iOS refuses GPU work there (and the 17 Pro reports no
//  background GPU for continued-processing tasks either), so an on-device brain
//  cannot finish the turn. Left alone, the turn kept the brain it was running on
//  alive: the background shed dropped the app's own reference, the return loaded
//  the brain AGAIN, and with two copies in memory iOS killed the app in front
//  (drilled on an iPhone 17 Pro, 2026-11-11: Lil mid-answer, background, return,
//  signal 9 two seconds later; the phone's memory log shows M1K3 at 3.9 GB).
//
//  So a turn on a brain that runs on this device's GPU is stopped at the exit: what
//  arrived stays in the transcript, marked interrupted, exactly as the Stop button
//  leaves it. A turn that runs elsewhere (Apple's model in its own process, Brain
//  at Home, Private Cloud) holds no weights here and is left alone.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.8, Prior: none (new file).
//  Open: stopping is the floor, not the ceiling. Picking the turn up again on the
//  return, or a Live Activity that says it is paused, is a design call (Kev).
//

import Foundation

public enum BackgroundExitPolicy {
    /// Whether the turn in flight is stopped when the app leaves for the background.
    public static func stopsTurn(turnInFlight: Bool, brainRunsOnThisDevicesGPU: Bool) -> Bool {
        turnInFlight && brainRunsOnThisDevicesGPU
    }
}
