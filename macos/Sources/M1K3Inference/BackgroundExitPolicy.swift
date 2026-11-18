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
//  Review: Kev + claude-opus-5.5, 2026-11-16 (#858: a step already on the GPU at the background event crashed the
//  app; the MLX error scope in M1K3MLX now turns that into a throw). Two rules added here: the same stop also runs at
//  `.inactive`, which comes first, so the loop drains while the GPU is still allowed (`stopsTurnAtInactive`), and the
//  shed waits, bounded, for the turn to have exited before it releases memory under a running evaluation
//  (`shedPlan`). Confidence 0.7: the rules are pure and tested, the effect is owed on a phone.
//  Open: a Private Cloud turn is stopped too when a brain is loaded on the device (the rule reads the loaded
//  brain, not the turn's route). Stopping is the floor, not the ceiling. Picking the turn up again on the
//  return, or a Live Activity that says it is paused, is a design call (Kev).
//  Review: Kev + claude-opus-5.5, 2026-11-16 — `wantsBackgroundGrace` (the complement of `stopsTurn`) so an off-GPU
//  turn finishes on a background task, and the Live Activity says "Paused" for the stopped ones (TurnActivityPolicy).
//  The Open's Live Activity half is built; the Private Cloud-with-a-loaded-brain stop is unchanged. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-11-17 (#862) — `shedPlan` waits on the chat turn OR any MLX evaluation: a title
//  prefill outlived the shed by 0.4 s on Kev's phone. Confidence 0.8; the phone check is owed (leave right after a
//  first exchange, while the title is being made).
//  Review: Kev + claude-opus-5.5, 2026-11-17 — the first Open is closed: `turnUsesThisDevicesGPU` reads the turn's
//  route (a Private Cloud answer is not this GPU, even with Lil loaded; a failed one's local fallback IS, so the shell
//  reads the route off the session's streaming answer, not a flag around the send), and every stop asks it.
//  Picking a stopped turn up again on the return stays a design call (Kev). Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-11-18 (#864 review fold) — a Private Cloud turn left running in the
//  background can fail there; its local fallback starts only in front or off this GPU
//  (BackgroundExitPolicy.mayRunLocalFallback, ChatSession.mayRunLocalFallback), else the notice says Lil can't
//  answer in the background and asks again on return.
//

import Foundation

public enum BackgroundExitPolicy {
    /// Whether the turn in flight runs on this device's GPU: a local brain is loaded AND the turn is not a Private
    /// Cloud one. Lil stays loaded through a Private Cloud turn, whose answer comes from Apple's servers, so the
    /// loaded brain alone stopped (and showed as Paused) a turn that would have finished in the background.
    /// Home needs no case: activating it releases the local brain.
    public static func turnUsesThisDevicesGPU(localBrainLoaded: Bool, privateCloudTurn: Bool) -> Bool {
        localBrainLoaded && !privateCloudTurn
    }

    /// Whether a Private Cloud turn's local fallback may start now: in front, or anywhere when the local brain is not
    /// on this device's GPU (Mini, Home). A cloud turn the exit let run can still fail in the background; starting Lil
    /// there submits GPU work iOS refuses (#864 review), so the notice asks again on return instead.
    public static func mayRunLocalFallback(appActive: Bool, localBrainLoaded: Bool) -> Bool {
        appActive || !localBrainLoaded
    }

    /// Whether the turn in flight is stopped when the app leaves for the background.
    public static func stopsTurn(turnInFlight: Bool, brainRunsOnThisDevicesGPU: Bool) -> Bool {
        turnInFlight && brainRunsOnThisDevicesGPU
    }

    /// Whether the turn in flight is worth a background-task grace so it can finish while the person is away:
    /// the exact complement of `stopsTurn` (a turn that runs elsewhere holds no weights here, and iOS would
    /// otherwise suspend the app within seconds and freeze it mid-answer). Never for an on-device brain.
    public static func wantsBackgroundGrace(turnInFlight: Bool, brainRunsOnThisDevicesGPU: Bool) -> Bool {
        turnInFlight && !brainRunsOnThisDevicesGPU
    }

    /// Whether the turn is stopped when the scene goes `.inactive`. `.inactive` precedes `.background` by a
    /// fraction of a second on every real exit (Home, app switcher, lock), and a step still on the GPU when the
    /// background lands is refused. The same condition as the exit itself, so nothing that survives the
    /// background is stopped early. The price: a transient `.inactive` that returns to `.active` (Control Center,
    /// a system alert) stops an on-device answer too. iOS gives no way to tell the two apart in time, and a
    /// stopped answer keeps what arrived, exactly as the Stop button leaves it. Voice and speech are NOT
    /// stopped at `.inactive`: that stays with the true background.
    public static func stopsTurnAtInactive(turnInFlight: Bool, brainRunsOnThisDevicesGPU: Bool) -> Bool {
        stopsTurn(turnInFlight: turnInFlight, brainRunsOnThisDevicesGPU: brainRunsOnThisDevicesGPU)
    }

    public enum ShedPlan: Sendable, Equatable {
        /// Release the brain's memory now.
        case shedNow
        /// A generation is still running: let it exit first.
        case waitForTurn
    }

    /// The longest the shed waits for a stopped turn to exit before it sheds anyway (jetsam hygiene wins).
    public static let shedWaitLimit: Duration = .seconds(1)

    /// Releasing buffers under an evaluation that is still running is its own hazard, so a shed waits, up to
    /// `shedWaitLimit`, while the chat turn is still responding OR any MLX evaluation is still running: a title
    /// or a memory distillation started just before the exit is not the chat turn, and the exit does not stop
    /// it (#862, Kev's phone 2026-11-16: a 181-token title prefill finished 0.4 s after the shed).
    public static func shedPlan(chatResponding: Bool, mlxEvaluating: Bool, waited: Duration) -> ShedPlan {
        (chatResponding || mlxEvaluating) && waited < shedWaitLimit ? .waitForTurn : .shedNow
    }

    public enum ReturnPlan: Sendable, Equatable {
        /// The brain the exit let go of is still in memory: use that one.
        case takeItBack
        /// It is gone: load it from disk.
        case loadAgain
    }

    /// Stopping the turn asks it to end; it does not wait. A turn cut during its prefill, or a title or a
    /// distillation in flight, can still hold the brain when the app comes back. Loading beside it is the
    /// two-copies kill, so the return never loads while the old one is alive.
    public static func onReturn(shedBrainStillLoaded: Bool) -> ReturnPlan {
        shedBrainStillLoaded ? .takeItBack : .loadAgain
    }
}
