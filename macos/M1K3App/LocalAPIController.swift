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
//  Open: verify-by-launch with a real client (curl, the OpenAI SDK, one editor).
//

import Foundation
import M1K3Inference
import M1K3LocalAPI
import M1K3MCPKit // LoopbackAccessTokenVault / Box: the token's mint, store and constant holder
import Observation
import os

@MainActor
@Observable
final class LocalAPIController {
    nonisolated static let enabledKey = "localAPI.enabled"
    nonisolated static let accessTokenAccount = "localapi.access-token"
    nonisolated static let port = LocalAPIServer.defaultPort

    private static let log = Logger(subsystem: "app.m1k3", category: "local-api")

    private unowned let env: AppEnvironment
    private var server: LocalAPIServer?
    private let tokenBox = LoopbackAccessTokenBox()

    private(set) var isEnabled: Bool
    private(set) var isRunning = false
    private(set) var statusText: String?
    private(set) var accessToken: String?

    /// What a client is told to use as its base URL.
    var baseURL: String {
        "http://127.0.0.1:\(Self.port)/v1"
    }

    init(environment: AppEnvironment) {
        env = environment
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
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
            complete: { [weak self] model, request in await self?.stream(model: model, request: request) }
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
    private func stream(model: String, request: RawChatRequest) -> RawChatStream? {
        guard readyModelIDs.contains(model), let raw = env.provider as? RawChatCompleting else { return nil }
        return raw.completeRawChat(request)
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
