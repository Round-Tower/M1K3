//
//  BrainServeController.swift
//  M1K3App
//
//  Brain at Home's MainActor glue (the MCPHostController shape): lifecycle for
//  the LAN TLS-PSK listener + Bonjour advertisement, the QR pairing ceremony,
//  the paired-device registry (metadata in UserDefaults, PSKs in the
//  Keychain), and the handler closures over the live app seams.
//
//  Security structure (docs/BRAIN_AT_HOME_SPEC.md):
//  - MAIN listener: paired devices' keys only. Serves generate/health (+ the
//    SCOPED /mcp session when its own toggle is on).
//  - PAIRING listener: exists only while the QR shows (≤60s), carries ONLY
//    the candidate key, serves ONLY /v1/pair. A candidate can't reach
//    /v1/generate by construction (audit B2 — prevention, not detection).
//    Nothing touches the Keychain until the human clicks Approve.
//  - Remote turns: admitted through RemoteTurnDecision (busy local turn or a
//    warm machine → 429 Retry-After; the phone falls back to its own ladder);
//    a NEW local turn preempts in-flight remote streams (audit S2).
//  - Revoke: Keychain key deleted + the main listener restarted without it —
//    live connections under that identity die with the restart (audit S3).
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.8 (the policy/wire
//  layers are package-TDD'd incl. real loopback TLS-PSK round-trips; this
//  glue is verify-by-launch — pairing UX + LAN reachability on real hardware
//  are the named verify-owed). Prior: MCPHostController.swift (the shape).
//

import CoreImage.CIFilterBuiltins
import Foundation
import M1K3BrainLink
import M1K3BrainServe
import M1K3Calls // KeychainKeyStore — PSKs at rest (afterFirstUnlock, device-only)
import M1K3Inference // RawCompletionProviding — the persona-free /v1/generate seam
import M1K3MCPKit
import MCP
import Observation
import os

@MainActor
@Observable
final class BrainServeController {
    nonisolated static let enabledKey = "brainServe.enabled"
    nonisolated static let portKey = "brainServe.port"
    nonisolated static let lanMCPKey = "brainServe.lanMCP.enabled"
    nonisolated static let devicesKey = "brainServe.devices"
    nonisolated static let defaultPort: UInt16 = 4243

    private nonisolated static let log = Logger(subsystem: "app.m1k3", category: "brain-serve")

    private unowned let env: AppEnvironment
    private let keyStore: any KeyStore
    private var listener: BrainServeListener?
    private var pairingListener: BrainServeListener?
    private var pairingExpiryTask: Task<Void, Never>?
    /// The candidate secret while the QR shows — committed to the Keychain
    /// ONLY on approve, discarded on cancel/expiry (audit B2).
    private var candidateSecret: Data?
    private let advertiser = BrainAdvertiser()
    /// The scoped LAN MCP session — rebuilt per initialize, like the loopback
    /// server's session (one LAN MCP client at a time, same v1 shape).
    private var lanMCPSession: (server: Server, transport: StatelessHTTPServerTransport)?
    /// Process-unique counter for the LAN route's JSON-RPC id isolation (#176):
    /// paired devices all number their requests from 1, so their ids must be
    /// remapped before the shared transport routes response waiters by id.
    private var lanRequestIDCounter: UInt64 = 0
    /// One job store for the controller's lifetime, so a LAN ask_m1k3 job
    /// survives a session rebuild (the loopback server's own rationale).
    private let lanAskJobStore = AskJobStore()

    private(set) var isRunning = false
    private(set) var statusText: String?
    private(set) var pairing = PairingSession()
    private(set) var pairingQRPayload: String?
    private(set) var pairedDevices: [PairedDevice] = []

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            Task { isEnabled ? await self.start() : await self.stopServing() }
        }
    }

    /// The second consent tier: the SCOPED MCP surface for paired devices.
    /// Its own toggle, default OFF — never inherited from the serve toggle.
    var lanMCPEnabled: Bool {
        didSet {
            UserDefaults.standard.set(lanMCPEnabled, forKey: Self.lanMCPKey)
            Task { await self.restartIfRunning() } // handler set changes
        }
    }

    var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        guard stored > 1023, stored <= 65535 else { return Self.defaultPort }
        return UInt16(stored)
    }

    init(environment: AppEnvironment, keyStore: any KeyStore = KeychainKeyStore()) {
        env = environment
        self.keyStore = keyStore
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        lanMCPEnabled = UserDefaults.standard.bool(forKey: Self.lanMCPKey)
        pairedDevices = Self.loadDevices()
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        Task { await start() }
    }

    // MARK: - Main listener lifecycle

    func start() async {
        guard listener == nil else { return }
        let credentials = loadCredentials()
        guard !credentials.isEmpty else {
            statusText = "On — pair a device to start serving"
            return
        }
        let host = BrainServeListener(
            port: port,
            credentials: credentials,
            handlers: makeHandlers(),
            onAbnormalStop: { [weak self] reason in
                Task { @MainActor [weak self] in
                    self?.listener = nil
                    self?.isRunning = false
                    self?.statusText = "Stopped: \(reason)"
                }
            }
        )
        do {
            try await host.start()
            listener = host
            isRunning = true
            let bound = await host.boundPort ?? port
            statusText = "Serving on :\(bound) to \(credentials.count) paired device\(credentials.count == 1 ? "" : "s")"
            advertiser.start(name: Host.current().localizedName ?? "M1K3", port: bound)
        } catch {
            listener = nil
            isRunning = false
            statusText = "Couldn’t start: \(error.localizedDescription)"
        }
    }

    func stopServing() async {
        advertiser.stop()
        await listener?.stop()
        listener = nil
        if let session = lanMCPSession {
            await session.server.stop()
            await session.transport.disconnect()
        }
        lanMCPSession = nil
        isRunning = false
        statusText = isEnabled ? "On — pair a device to start serving" : nil
        cancelPairing()
    }

    private func restartIfRunning() async {
        guard listener != nil else { return }
        await stopServing()
        await start()
    }

    /// A new LOCAL turn preempts every in-flight remote stream (audit S2) —
    /// called at the top of AppEnvironment.send.
    nonisolated func preemptForLocalTurn() {
        Task { @MainActor in
            guard let listener = self.listener else { return }
            await listener.cancelActiveGenerations()
        }
    }

    // MARK: - Handlers over the live app seams

    private func makeHandlers() -> BrainServeHandlers {
        let admit: @Sendable () async -> RemoteTurnDecision = { [weak self] in
            guard let self else { return .busyLocal(retryAfterSeconds: 15) }
            return await self.admitRemoteTurn()
        }
        let generate: @Sendable (GenerateRequest) async -> AsyncStream<String>? = { [weak self] request in
            guard let self else { return nil }
            return await self.remoteStream(for: request)
        }
        let health: @Sendable () async -> String = { [weak self] in
            guard let self else { return #"{"ok":false}"# }
            return await self.healthJSON()
        }
        var mcp: (@Sendable (HTTPRequest) async -> HTTPResponse)?
        if lanMCPEnabled {
            mcp = { [weak self] request in
                guard let self else {
                    return .error(statusCode: 500, MCPError.internalError("brain serve shutting down"))
                }
                return await self.handleLANMCP(request)
            }
        }
        return BrainServeHandlers(admit: admit, generate: generate, healthJSON: health, mcp: mcp)
    }

    private func admitRemoteTurn() -> RemoteTurnDecision {
        RemoteTurnDecision.decide(
            localBusy: env.chat.isResponding
                || env.voiceLoop != nil
                || env.intelligenceAskInFlight,
            // The same thermal+low-power read Prudent Compute uses for
            // background work — remote turns yield first (§8a.3).
            thermalPressure: !AppEnvironment.backgroundWorkAllowed(),
            // Not-ready refuses BEFORE the provider is touched, so a remote
            // request can never trigger a model load/download as a side
            // effect (2026-08-19 audit fold).
            notReady: !env.isReady
        )
    }

    /// The runtime façade — brain switches and the interim-Mini bridge route
    /// remote turns exactly like local ones, but through the RAW seam:
    /// `RawCompletionProviding` opens a session with NO persona, no KV seed,
    /// no tools, no retrieval (2026-08-19 audit, finding 1 — a network
    /// surface primed with the persona is a prefix-extraction target, so
    /// raw-ness is structural, not filtered). nil → the listener answers 503.
    private func remoteStream(for request: GenerateRequest) -> AsyncStream<String>? {
        guard let raw = env.provider as? RawCompletionProviding else { return nil }
        return raw.generateRawStreaming(prompt: request.prompt, maxTokens: request.maxTokens)
    }

    private func healthJSON() -> String {
        let brain = env.selectedBrain.displayName
        let ready = env.isReady
        return "{\"ok\":true,\"brain\":\"\(brain)\",\"ready\":\(ready),\"v\":\"1\"}"
    }

    /// The scoped LAN MCP surface: the SAME tool implementations the loopback
    /// server dispatches, filtered to the read/ask allowlist (MCPToolScope.lan)
    /// — remember/forget/speak/listen/open_link never leave the Mac's own
    /// loopback. Session rebuild on initialize, the LocalMCPHTTPServer shape.
    private func handleLANMCP(_ request: HTTPRequest) async -> HTTPResponse {
        if let body = request.body, HTTPWireCodec.isInitializeRequest(body: body) {
            if let session = lanMCPSession {
                await session.server.stop()
                await session.transport.disconnect()
            }
            let registry = MCPToolRegistry(
                scopedToolDefinitions(
                    // preemptsRemoteStreams: false — a paired device's ask_m1k3
                    // must never cancel ANOTHER paired device's stream (review
                    // fold). Single-flight is still enforced by admitRemoteTurn.
                    env.mcpHost.makeAllToolDefinitions(
                        jobStore: lanAskJobStore, preemptsRemoteStreams: false
                    ),
                    scope: .lan
                ),
                logSink: env.conversationLog
            )
            // NOT the default pipeline: OriginValidator.localhost() allows
            // only 127.0.0.1/localhost Hosts, which rejects every real LAN
            // client with 421 (live-fired 2026-08-19). Host/Origin checking
            // defends BROWSERS against DNS rebinding — and a browser CANNOT
            // reach this route at all: fetch/XHR/WebSocket have no API to
            // supply an external TLS-PSK identity+key, so the handshake this
            // route sits behind fails for any browser before a byte of HTTP
            // exists. The PSK is therefore a strictly stronger authenticator
            // than Host matching here. The other validators stay. Loopback
            // :4242 keeps the localhost default.
            let transport = StatelessHTTPServerTransport(
                validationPipeline: StandardValidationPipeline(validators: [
                    OriginValidator.disabled,
                    AcceptHeaderValidator(mode: .jsonOnly),
                    ContentTypeValidator(),
                    ProtocolVersionValidator(),
                ])
            )
            let server = await makeM1K3Server(registry: registry, name: "m1k3-brain")
            do {
                try await server.start(transport: transport)
                lanMCPSession = (server, transport)
            } catch {
                Self.log.error("lan mcp session rebuild failed: \(error.localizedDescription, privacy: .public)")
                lanMCPSession = nil
                return .error(statusCode: 500, MCPError.internalError("MCP session rebuild failed"))
            }
        }
        guard let transport = lanMCPSession?.transport else {
            return .error(statusCode: 500, MCPError.internalError("MCP session unavailable"))
        }
        // The LAN transport routes response waiters by the client-chosen id
        // GLOBALLY too, and each paired device numbers from 1 — so the #176
        // collision was still live on this route (the loopback fix never reached
        // it). Isolate every request's id, exactly as the loopback server does.
        lanRequestIDCounter &+= 1
        guard let isolated = MCPRequestIDRemap.isolate(request, as: .string("m1k3-lan#\(lanRequestIDCounter)")) else {
            Self.log.error("lan id-remap re-encode failed; forwarding un-isolated request (collision risk)")
            return await transport.handleRequest(request)
        }
        let response = await transport.handleRequest(isolated.request)
        return MCPRequestIDRemap.restore(response, to: isolated.clientID)
    }

    // MARK: - Pairing ceremony

    /// Reentrancy guard for the ceremony: `beginPairing` suspends at listener
    /// start, and a double-tap interleaving there would orphan a listener +
    /// secret (2026-08-19 audit, note 12).
    private var beginPairingInFlight = false

    /// Show the QR: mint a candidate secret + identity, spin the short-lived
    /// pairing listener (candidate key ONLY), and hand the UI its payload.
    func beginPairing() async {
        guard !beginPairingInFlight else { return }
        // A candidate already awaiting the human's Approve is never silently
        // clobbered by a re-display — the same invariant PairingSession pins
        // (audit note 11); without this check the unconditional
        // cancelPairing() below would reset the phase first and the pure
        // guard could never fire (PR #139 review).
        if case .awaitingApproval = pairing.phase {
            statusText = "A device is waiting for approval — approve or decline it first"
            return
        }
        beginPairingInFlight = true
        defer { beginPairingInFlight = false }
        // AWAIT the teardown of any prior pairing listener before minting the
        // new one — NOT the fire-and-forget cancelPairing(). Its unstructured
        // Task could otherwise resume AFTER `pairingListener = host` below and
        // tear down the brand-new listener, stranding a live QR that can never
        // complete a handshake (2026-08-19 review fold).
        await cancelPairingAndTeardown()
        var secret = Data(count: 32)
        let status = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else {
            statusText = "Couldn’t mint a pairing secret"
            return
        }
        let identity = UUID().uuidString
        let credential = PSKCredential(identity: identity, key: secret)
        let host = BrainServeListener(
            port: 0, // ephemeral — the QR carries whatever binds
            credentials: [credential],
            handlers: BrainServeHandlers(
                admit: { .busyLocal(retryAfterSeconds: 3600) }, // no generation for candidates
                generate: { _ in nil },
                healthJSON: { #"{"pairing":true}"# },
                mcp: nil,
                pair: { [weak self] request in
                    await self?.pairRequestArrived(name: request.deviceName, identity: identity)
                        ?? #"{"error":"pairing closed"}"#
                }
            )
        )
        do {
            try await host.start()
        } catch {
            statusText = "Couldn’t open pairing: \(error.localizedDescription)"
            return
        }
        guard let pairingPort = await host.boundPort else {
            await host.stop()
            return
        }
        pairingListener = host
        candidateSecret = secret
        pairing.beginDisplay(identity: identity, now: Date())
        let mac = Host.current().localizedName ?? "M1K3"
        // Composed through the SHARED payload type (round-trip-pinned against
        // the device's parser) — and it now carries the Mac's LAN addresses:
        // the QR is the only channel a first-time device has, because the
        // Bonjour advertiser only runs once a paired device already exists.
        pairingQRPayload = PairingPayload(
            psk: secret,
            identity: identity,
            pairingPort: pairingPort,
            mainPort: port,
            macName: mac,
            hosts: LANAddresses.current()
        ).composed()
        // Auto-expiry (≤60s): the candidate is discarded, the QR goes away.
        pairingExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(PairingSession.displayTTL))
            guard let self, !Task.isCancelled else { return }
            if pairing.tick(now: Date()) {
                pairingQRPayload = nil
                candidateSecret = nil
                await teardownPairingListener()
            }
        }
    }

    /// The candidate completed the PSK handshake on the pairing listener and
    /// asked to pair — surface the Approve decision (audit B2).
    private func pairRequestArrived(name: String, identity: String) -> String {
        if pairing.pairRequested(candidateName: name, identity: identity, now: Date()) {
            return #"{"status":"pending-approval"}"#
        }
        return #"{"error":"pairing expired — regenerate the code on the Mac"}"#
    }

    /// The human clicked Approve: NOW the secret reaches the Keychain, the
    /// device joins the registry, and the main listener restarts with it.
    func approvePairing() async {
        guard let device = pairing.approve(now: Date()), let secret = candidateSecret else { return }
        do {
            try keyStore.setData(secret, forAccount: Self.keychainAccount(for: device.identity))
        } catch {
            Self.log.error("pairing: keychain write failed: \(error.localizedDescription, privacy: .public)")
            statusText = "Couldn’t store the pairing key"
            cancelPairing()
            return
        }
        pairedDevices.append(device)
        Self.saveDevices(pairedDevices)
        candidateSecret = nil
        pairingQRPayload = nil
        await teardownPairingListener()
        await restartIfRunning()
        if listener == nil { await start() } // first device: bring the service up
        Self.log.notice("pairing: approved \"\(device.name, privacy: .public)\"")
    }

    /// The synchronous state reset shared by both cancel paths.
    private func clearPairingState() {
        pairing.cancel()
        pairingQRPayload = nil
        candidateSecret = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
    }

    /// Decline / close the sheet (a SYNCHRONOUS SwiftUI button action, so the
    /// listener teardown is fire-and-forget): the candidate never existed (B2).
    func cancelPairing() {
        clearPairingState()
        Task { await teardownPairingListener() }
    }

    /// The ORDERED cancel `beginPairing` awaits — the teardown completes before
    /// the new listener is minted, closing the fire-and-forget race.
    private func cancelPairingAndTeardown() async {
        clearPairingState()
        await teardownPairingListener()
    }

    private func teardownPairingListener() async {
        await pairingListener?.stop()
        pairingListener = nil
    }

    /// Revoke: key gone + listener restarted without it — any live connection
    /// under that identity dies with the restart (audit S3).
    func revoke(_ device: PairedDevice) async {
        try? keyStore.removeData(forAccount: Self.keychainAccount(for: device.identity))
        pairedDevices.removeAll { $0.identity == device.identity }
        Self.saveDevices(pairedDevices)
        await restartIfRunning()
        if pairedDevices.isEmpty { await stopServing() }
    }

    // MARK: - Persistence

    private nonisolated static func keychainAccount(for identity: String) -> String {
        "brainserve-psk-\(identity)"
    }

    private func loadCredentials() -> [PSKCredential] {
        pairedDevices.compactMap { device in
            guard let key = try? keyStore.data(forAccount: Self.keychainAccount(for: device.identity)) else {
                return nil
            }
            return PSKCredential(identity: device.identity, key: key)
        }
    }

    private nonisolated static func loadDevices() -> [PairedDevice] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey) else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    private nonisolated static func saveDevices(_ devices: [PairedDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: devicesKey)
        }
    }

    // MARK: - QR rendering

    /// The pairing QR as an image (nil while no ceremony is running).
    var pairingQRImage: CGImage? {
        guard let payload = pairingQRPayload else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            return nil
        }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
