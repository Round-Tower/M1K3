//
//  PairingCeremony.swift
//  M1K3BrainLink
//
//  The device's side of the one-time QR ceremony (BRAIN_AT_HOME_SPEC §4):
//
//    1. POST /v1/pair to the Mac's ephemeral pairing listener (over TLS-PSK
//       with the QR's candidate credential) — expect pending-approval.
//    2. Poll GET /v1/health on the MAIN port with the SAME credential. The
//       handshake succeeding IS the "paired" signal — the main listener only
//       gains this key when the human clicks Approve, and the pairing
//       listener is gone by then.
//
//  The transport is injected so the flow is table-tested; the default is
//  BrainConnection.request. Every exit is a message, never a hang — the
//  approval window bounds the poll.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.85 (flow TDD'd
//  over a scripted transport; the live ceremony against a real Mac is the
//  named hardware verify). Prior: BRAIN_AT_HOME_SPEC §4.
//

import Foundation
import M1K3LogCore
import os

/// A Mac this device paired with. Metadata only — the PSK lives in the
/// device Keychain under `identity` (BrainLinkKeyStore).
public struct PairedBrain: Sendable, Equatable, Codable, Identifiable {
    public var id: String {
        identity
    }

    /// The opaque PSK identity minted by the Mac (never a device name).
    public let identity: String
    /// The Mac's display name, for the UI.
    public let name: String
    /// Candidate addresses from the QR, in the Mac's preference order.
    public let hosts: [String]
    public let mainPort: UInt16
    /// The address that most recently worked — dialed first.
    public var lastKnownHost: String?
    public let addedAt: Date

    public init(
        identity: String, name: String, hosts: [String], mainPort: UInt16,
        lastKnownHost: String?, addedAt: Date
    ) {
        self.identity = identity
        self.name = name
        self.hosts = hosts
        self.mainPort = mainPort
        self.lastKnownHost = lastKnownHost
        self.addedAt = addedAt
    }

    /// Dial order: what worked last, then the QR's remaining candidates.
    public var dialOrder: [String] {
        guard let last = lastKnownHost else { return hosts }
        return [last] + hosts.filter { $0 != last }
    }
}

public actor PairingCeremony<PollClock: Clock> where PollClock.Duration == Duration {
    /// One buffered request: (requestBytes, host, port, credential) → head+body.
    public typealias Transport = @Sendable (Data, String, UInt16, PSKCredential) async throws
        -> (head: HTTPResponseHead, body: Data)

    public enum Outcome: Sendable, Equatable {
        case paired(PairedBrain, BrainHealth)
        case failed(String)
    }

    /// Progress milestones for the pairing UI.
    public enum Phase: Sendable, Equatable {
        /// Dialing the pairing listener on the QR's addresses.
        case contacting
        /// The Mac has the request — a human is deciding (show "Approve on
        /// your Mac…").
        case awaitingApproval
    }

    private static var log: Logger {
        M1K3Log.logger(.brainLink)
    }

    private let transport: Transport
    private let pollInterval: Duration
    private let approvalWindow: Duration
    private let clock: PollClock

    public init(
        transport: @escaping Transport = { bytes, host, port, credential in
            try await BrainConnection.request(bytes, host: host, port: port, credential: credential)
        },
        pollInterval: Duration = .seconds(2),
        approvalWindow: Duration = .seconds(180),
        clock: PollClock = ContinuousClock()
    ) {
        self.transport = transport
        self.pollInterval = pollInterval
        self.approvalWindow = approvalWindow
        self.clock = clock
    }

    /// Run the whole ceremony. Never throws — every exit is an Outcome the
    /// pairing UI can show; `onPhase` reports the milestones along the way.
    public func pair(
        payload: PairingPayload, deviceName: String,
        onPhase: (@Sendable (Phase) -> Void)? = nil
    ) async -> Outcome {
        onPhase?(.contacting)
        guard !payload.hosts.isEmpty else {
            return .failed(
                "This pairing code carries no address for the Mac — update M1K3 on the Mac and show a fresh code."
            )
        }
        let credential = payload.credential

        // Step 1: reach the pairing listener on any of the QR's addresses.
        var reachedHost: String?
        var lastError = "couldn’t reach the Mac"
        for host in payload.hosts {
            do {
                let (_, body) = try await transport(
                    BrainLinkFrames.post(
                        "/v1/pair", host: host,
                        body: BrainLinkFrames.pairBody(deviceName: deviceName)
                    ),
                    host, payload.pairingPort, credential
                )
                switch PairResponse.parse(body) {
                case .pendingApproval:
                    reachedHost = host
                case let .rejected(message):
                    return .failed(message)
                }
            } catch {
                lastError = Self.describe(error)
                continue
            }
            break
        }
        guard let pairedHost = reachedHost else {
            Self.log.notice("pairing: no QR host reachable")
            return .failed(
                "Couldn’t reach the Mac (\(lastError)). Make sure both devices are on the same Wi-Fi and the code is fresh."
            )
        }

        // Step 2: poll the main port until Approve lands the key there.
        onPhase?(.awaitingApproval)
        let deadline = clock.now.advanced(by: approvalWindow)
        while clock.now < deadline {
            do {
                let (head, body) = try await transport(
                    BrainLinkFrames.get("/v1/health", host: pairedHost),
                    pairedHost, payload.mainPort, credential
                )
                if head.status == 200, let health = BrainHealth.parse(body), health.ok {
                    let brain = PairedBrain(
                        identity: payload.identity,
                        name: payload.macName,
                        hosts: payload.hosts,
                        mainPort: payload.mainPort,
                        lastKnownHost: pairedHost,
                        addedAt: Date()
                    )
                    Self.log.notice("pairing: approved by \(brain.name, privacy: .public)")
                    return .paired(brain, health)
                }
            } catch {
                // Expected while the human decides: no listener / handshake
                // refused. Keep polling until the window closes.
            }
            try? await clock.sleep(for: pollInterval)
        }
        return .failed(
            "The Mac never approved this device — click Approve on the Mac while the code is showing, then try again."
        )
    }

    private static func describe(_ error: Error) -> String {
        switch error as? BrainLinkError {
        case let .unreachable(reason): reason
        case .timedOut: "timed out"
        case let .refused(refusal): refusal.userMessage
        case let .unavailable(reason): reason
        case let .badResponse(reason): reason
        case let .streamInterrupted(reason): reason
        case nil: error.localizedDescription
        }
    }
}
