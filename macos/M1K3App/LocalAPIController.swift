//
//  LocalAPIController.swift
//  M1K3App
//
//  The Mac app's glue for the Local API (M1K3LocalAPI): M1K3's brains for other
//  apps on this Mac, in the wire shape OpenAI clients speak. OFF by default.
//  Everything it decides lives in tested packages; this is the lifecycle, the
//  token, and three closures over the live app.
//
//  What a caller gets: the brain that is loaded right now, raw. Its own system
//  message is the whole system prompt: no persona, no memory, no knowledge, no
//  tools, and nothing is written to chat history or distilled. It never loads
//  or swaps a brain: a model that is not the selected, ready one is "not found".
//  The person at the Mac goes first: a call that arrives while they chat is told
//  to come back, and a call in flight ends when they start (`preemptForLocalTurn`,
//  called beside Brain at Home's).
//
//  Its own token (Keychain account `localapi.access-token`), never the MCP
//  server's: that one also unlocks memory and speech, and an API key ends up in
//  other tools' config files.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.6, Prior: none (new
//  file; the lifecycle and token handling follow MCPHostController, the
//  admission rule BrainServeController.admitRemoteTurn).
//  Review: Kev + claude-fable-5.2, 2026-11-11 (night) — the Open is retired in part: curl and the OpenAI Python
//  SDK ran against all three brains by launch on 11-11, and Kev's own curl against Big (#801). Confidence 0.75.
//  Review: Kev + claude-fable-5.2, 2026-11-11 (#621) — `isAnswering()`: the launch warm asks and waits. Confidence
//  unchanged.
//  Review: Kev + claude-fable-5.2, 2026-11-12 — a second model id, `cloud-m1k3`: Apple's Private Cloud Compute, lent
//  behind its OWN switch (off by default) and the chat rung's gate, re-read on every call (`PrivateCloudLending`,
//  ADR 0011). It carries the caller's words only. Every call that leaves is counted on the pane and logged at
//  notice. Confidence 0.6: pinned in the packages; the real service is verify-by-launch on a store-lane build.
//  Review: Kev + claude-fable-5.2, 2026-11-12 (later) — "its own system message is the whole system prompt" now holds
//  for Lil and Big; a lent Apple model (Mini, the cloud) runs behind one acceptable-use line (`LentAppleModelGuardrail`).
//  Open: an editor or a web UI as the client; a chat or voice turn ending a live call, in the hand; `cloud-m1k3`
//  against the real service.
//

import Foundation
import M1K3Agent // PrivateCloudRawChat
import M1K3Inference
import M1K3LanguageModel // PrivateCloudLending / PrivateCloudRung
import M1K3LocalAPI
import M1K3MCPKit // LoopbackAccessTokenVault / Box: the token's mint, store and constant holder
import Observation
import os

@MainActor
@Observable
final class LocalAPIController {
    nonisolated static let enabledKey = "localAPI.enabled"
    nonisolated static let accessTokenAccount = "localapi.access-token"
    /// The lending switch for Private Cloud Compute on THIS surface. Off by default.
    nonisolated static let lendPrivateCloudKey = "localAPI.lendPrivateCloud"
    nonisolated static let port = LocalAPIServer.defaultPort

    private static let log = Logger(subsystem: "app.m1k3", category: "local-api")

    private unowned let env: AppEnvironment
    private var server: LocalAPIServer?
    private let tokenBox = LoopbackAccessTokenBox()

    private(set) var isEnabled: Bool
    private(set) var isRunning = false
    private(set) var statusText: String?
    private(set) var accessToken: String?
    private(set) var lendsPrivateCloud: Bool

    /// What a client is told to use as its base URL.
    var baseURL: String {
        "http://127.0.0.1:\(Self.port)/v1"
    }

    init(environment: AppEnvironment) {
        env = environment
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        lendsPrivateCloud = UserDefaults.standard.bool(forKey: Self.lendPrivateCloudKey)
    }

    func setLendsPrivateCloud(_ on: Bool) {
        lendsPrivateCloud = on
        UserDefaults.standard.set(on, forKey: Self.lendPrivateCloudKey)
    }

    /// What a caller is offered of Private Cloud Compute right now: this surface's switch AND the chat rung's
    /// gate (a backend, no organisation policy against it, the Privacy pane's switch), read fresh each time.
    var privateCloudOffer: PrivateCloudLending.Offer {
        PrivateCloudLending.offer(
            switchOn: lendsPrivateCloud,
            control: PrivateCloudRung.control(env.privateCloudState(consent: env.privateCloudConsentPersisted))
        )
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        settle()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        settle()
    }

    /// Starts and stops run ONE AT A TIME, each after the one before, and each reads the switch when its
    /// turn comes. A quick off-on-off can therefore never leave the server running with the switch off.
    private var lifecycle: Task<Void, Never>?

    private func settle() {
        let previous = lifecycle
        lifecycle = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if isEnabled { await start() } else { await stop() }
        }
    }

    /// The model ids a caller can use right now: the selected brain, once it is ready. Never more: this
    /// surface does not load or swap brains. `isReady` is the app's own "the selected brain is loaded and
    /// can answer" (the reading Brain at Home refuses on), so the provider's load call inside a raw chat
    /// finds the brain already there. During a brain swap `isReady` is false and the list is empty.
    var readyModelIDs: [String] {
        PrivateCloudLending.modelIDs(local: localModelIDs, offer: privateCloudOffer)
    }

    /// The brain on this Mac that can answer now. Listed first, always.
    var localModelIDs: [String] {
        env.isReady ? [LocalAPIModel.id(forTier: env.selectedBrain.rawValue)] : []
    }

    // MARK: - Lifecycle

    func start() async {
        guard server == nil else { return }
        guard loadAccessToken() != nil else {
            statusText = "Couldn’t start: the access token couldn’t be read from the Keychain"
            return
        }
        let backend = LocalAPIBackend(
            models: { [weak self] in await self?.readyModelIDs ?? [] },
            userBusy: { [weak self] in await self?.userBusy ?? true },
            complete: { [weak self] model, request in await self?.stream(model: model, request: request) },
            whyUnlisted: { [weak self] model in await self?.whyUnlisted(model) }
        )
        let tokenBox = tokenBox
        let handler = LocalAPIHandler(port: Self.port, token: { tokenBox.current() }, backend: backend)
        let server = LocalAPIServer(port: Self.port, handler: handler) { [weak self] reason in
            Task { @MainActor in
                self?.server = nil
                self?.isRunning = false
                self?.statusText = reason
            }
        }
        do {
            try await server.start()
            self.server = server
            isRunning = true
            statusText = "Listening on 127.0.0.1:\(Self.port)"
        } catch {
            Self.log.error("Local API failed to start: \(String(describing: error), privacy: .public)")
            statusText = "Couldn’t start: port \(Self.port) is already in use on this Mac"
        }
    }

    func stop() async {
        await server?.stop()
        server = nil
        isRunning = false
        statusText = nil
    }

    /// Whether a caller is being answered right now (the launch warm waits for it, #621).
    func isAnswering() async -> Bool {
        await server?.isAnswering ?? false
    }

    /// The person at the Mac has started a turn: a Local API call in flight ends now.
    nonisolated func preemptForLocalTurn() {
        Task { @MainActor in
            await self.server?.preempt()
        }
    }

    // MARK: - The three closures

    /// The same reading Brain at Home uses: chatting, in voice mode, or an ask in flight.
    private var userBusy: Bool {
        env.chat.isResponding || env.voiceLoop != nil || env.intelligenceAskInFlight
    }

    /// A raw chat on the loaded brain. Nil when the model asked for is not the ready one, or the brain
    /// cannot serve a raw chat: the handler says "not found".
    private func stream(model: String, request: RawChatRequest) async -> RawChatStream? {
        if model == PrivateCloudLending.modelID { return await privateCloudStream(request) }
        guard localModelIDs.contains(model), let raw = env.provider as? RawChatCompleting else { return nil }
        return raw.completeRawChat(request)
    }

    /// The cloud model exists in this build but is not offered right now (a switch is off): the caller is told
    /// where the switch is. Any other unlisted model is simply not found.
    private func whyUnlisted(_ model: String) -> RawChatFailure? {
        model == PrivateCloudLending.modelID && AppEnvironment.privateCloudBackend != nil ? .notOffered : nil
    }

    /// The one path on this surface that leaves the Mac. The gate is read again HERE, after a fresh status, so
    /// a switch turned off since the model list was read ends it. Nil (the handler's plain "not found") only
    /// where Private Cloud Compute cannot exist in this build; otherwise a stream that throws its reason:
    /// not switched on, unreachable, the limit spent, or M1K3's own hourly cap.
    private func privateCloudStream(_ request: RawChatRequest) async -> RawChatStream? {
        guard let backend = AppEnvironment.privateCloudBackend else { return nil }
        await env.refreshPrivateCloudStatus()
        let offer = privateCloudOffer
        if let refusal = PrivateCloudRawChat.refusal(for: offer) { return PrivateCloudRawChat.refused(refusal) }
        if let wait = env.privateCloudLendingBudget.spend(now: Date()) {
            return PrivateCloudRawChat.refused(.overBudget(retryAfter: wait))
        }
        // The send starts with the stream below. A person starting a turn in the instant after this returns
        // has the handler drop the stream, which cancels it: that call is counted here but answers nobody.
        let calls = env.privateCloudLendingTally.countLocalAPI()
        Self.log.notice("a call left for Private Cloud Compute (\(calls, privacy: .public) since launch)")
        return PrivateCloudRawChat.stream(request, backend: backend)
    }

    // MARK: - Access token

    @discardableResult
    func loadAccessToken() -> String? {
        if let accessToken { return accessToken }
        #if DEBUG
            // Verify-by-launch only: a Debug build takes its key from the launch environment, so a check can
            // call the API without anyone reading the Keychain. Not compiled into Release (pinned by a scan).
            if let test = ProcessInfo.processInfo.environment["M1K3_LOCAL_API_TEST_KEY"], test.count >= 24 {
                tokenBox.set(test)
                accessToken = test
                return test
            }
        #endif
        let store = AppEnvironment.makeKeyStore()
        let account = Self.accessTokenAccount
        do {
            let token = try LoopbackAccessTokenVault.loadOrMint(
                read: { try store.data(forAccount: account).map { String(decoding: $0, as: UTF8.self) } },
                save: { try store.setData(Data($0.utf8), forAccount: account) }
            )
            tokenBox.set(token)
            accessToken = token
            return token
        } catch {
            Self.log.error("Local API token unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A new token, in force from the next request. False leaves the old one.
    @discardableResult
    func rotateAccessToken() -> Bool {
        let store = AppEnvironment.makeKeyStore()
        let account = Self.accessTokenAccount
        do {
            let token = try LoopbackAccessTokenVault.rotate(
                save: { try store.setData(Data($0.utf8), forAccount: account) }
            )
            tokenBox.set(token)
            accessToken = token
            Self.log.notice("Local API token rotated")
            return true
        } catch {
            Self.log.error("Local API token rotation failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
