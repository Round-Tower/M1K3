//
//  AppCore+BrainLink.swift
//  M1K3iOS / M1K3visionOS
//
//  Brain at Home, device side: the pairing ceremony driver and the health
//  reading the Settings card shows. The slot re-pointing itself lives in
//  AppCore.swift (it touches the private provider/warm members); this file
//  is the UI-facing flow glue.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.85 (flow glue
//  over the TDD'd ceremony; the live pairing against a real Mac is the
//  Phase C hardware verify). Prior: BRAIN_AT_HOME_SPEC §4.
//

import Foundation
import M1K3BrainLink
import UIKit

extension AppCore {
    /// Run the QR ceremony end-to-end: parse → pair → poll for Approve →
    /// persist + surface. Returns nil on success, or a user-facing message.
    /// `onAwaitingApproval` fires when the request has reached the Mac and a
    /// human is deciding (show "Approve on your Mac…").
    func pairWithMac(
        payloadString: String,
        onAwaitingApproval: @escaping @MainActor () -> Void
    ) async -> String? {
        guard let payload = PairingPayload.parse(payloadString.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return "That doesn’t look like an M1K3 pairing code — show the QR in the Mac’s Settings → Privacy → Brain at Home."
        }
        let ceremony = PairingCeremony()
        let outcome = await ceremony.pair(
            payload: payload,
            deviceName: UIDevice.current.name,
            onPhase: { phase in
                guard phase == .awaitingApproval else { return }
                Task { @MainActor in onAwaitingApproval() }
            }
        )
        switch outcome {
        case let .paired(brain, _):
            guard adoptPairedBrain(brain, key: payload.psk) else {
                return "Paired, but this device couldn’t store the key — try again."
            }
            return nil
        case let .failed(message):
            return message
        }
    }

    /// One live health reading from the paired Mac (dial order, short
    /// timeout) — the Settings card's status line. nil = unreachable.
    func homeBrainHealth() async -> BrainHealth? {
        guard let brain = homeBrain, let credential = brainLinkStore.credential() else { return nil }
        for host in brain.dialOrder {
            guard let (head, body) = try? await BrainConnection.request(
                BrainLinkFrames.get("/v1/health", host: host),
                host: host, port: brain.mainPort, credential: credential,
                timeout: .seconds(4)
            ), head.status == 200 else { continue }
            return BrainHealth.parse(body)
        }
        return nil
    }
}
