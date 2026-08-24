//
//  HomeBrainProviderTests.swift
//  M1K3BrainLinkTests
//
//  The Mac's brain as an InferenceProvider on the device: token flow, the
//  dial-order fallback across the QR's hosts, etiquette refusals rendered as
//  friendly words (never a silent empty answer), and the persistence hook
//  for the host that actually worked. Store round-trips ride an isolated
//  UserDefaults suite + an in-memory key store.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.9 (pure over an
//  injected stream transport, TDD'd red-first). Prior: Unknown.
//

import Foundation
import M1K3BrainLink
import M1K3Inference
import os
import Testing

private let key = Data((0 ..< 32).map { UInt8($0) })

private func brain(hosts: [String] = ["192.168.1.24"], last: String? = nil) -> PairedBrain {
    PairedBrain(
        identity: "ID-1", name: "Studio", hosts: hosts, mainPort: 4243,
        lastKnownHost: last, addedAt: Date(timeIntervalSince1970: 0)
    )
}

/// Scripted per-host stream results.
private struct ScriptedStreams {
    enum Behaviour {
        case tokens([String])
        case failsBeforeTokens(BrainLinkError)
        case breaksAfter([String], BrainLinkError)
    }

    let byHost: [String: Behaviour]

    func transport() -> HomeBrainProvider.StreamTransport {
        { [byHost] _, host, _, _ in
            AsyncThrowingStream { continuation in
                switch byHost[host] {
                case let .tokens(tokens):
                    for token in tokens {
                        continuation.yield(token)
                    }
                    continuation.finish()
                case let .failsBeforeTokens(error):
                    continuation.finish(throwing: error)
                case let .breaksAfter(tokens, error):
                    for token in tokens {
                        continuation.yield(token)
                    }
                    continuation.finish(throwing: error)
                case nil:
                    continuation.finish(throwing: BrainLinkError.unreachable("unscripted host \(host)"))
                }
            }
        }
    }
}

private func collect(_ stream: AsyncStream<String>) async -> String {
    var out = ""
    for await chunk in stream {
        out += chunk
    }
    return out
}

struct HomeBrainProviderTests {
    @Test func streamsTokensAndRemembersTheWorkingHost() async {
        let updates = OSAllocatedUnfairLock<[PairedBrain]>(initialState: [])
        let provider = HomeBrainProvider(
            brain: brain(), key: key,
            transport: ScriptedStreams(byHost: ["192.168.1.24": .tokens(["Hi ", "Kev"])]).transport(),
            onBrainUpdate: { updated in updates.withLock { $0.append(updated) } }
        )
        let answer = await collect(provider.generateStreaming(prompt: "hello"))
        #expect(answer == "Hi Kev")
        #expect(updates.withLock { $0.last?.lastKnownHost } == "192.168.1.24")
    }

    @Test func fallsThroughToTheSecondHostWhenTheFirstIsUnreachable() async {
        let provider = HomeBrainProvider(
            brain: brain(hosts: ["10.0.0.9", "192.168.1.24"]), key: key,
            transport: ScriptedStreams(byHost: [
                "10.0.0.9": .failsBeforeTokens(.unreachable("no route")),
                "192.168.1.24": .tokens(["ok"]),
            ]).transport(),
            onBrainUpdate: { _ in }
        )
        let answer = await collect(provider.generateStreaming(prompt: "hello"))
        #expect(answer == "ok")
    }

    @Test func lastKnownHostIsDialedFirst() async {
        // Both hosts would answer differently; last-known must win.
        let provider = HomeBrainProvider(
            brain: brain(hosts: ["10.0.0.9", "192.168.1.24"], last: "192.168.1.24"), key: key,
            transport: ScriptedStreams(byHost: [
                "10.0.0.9": .tokens(["wrong host"]),
                "192.168.1.24": .tokens(["right host"]),
            ]).transport(),
            onBrainUpdate: { _ in }
        )
        let answer = await collect(provider.generateStreaming(prompt: "hello"))
        #expect(answer == "right host")
    }

    @Test func refusalBecomesFriendlyWordsNotSilence() async {
        let provider = HomeBrainProvider(
            brain: brain(), key: key,
            transport: ScriptedStreams(byHost: [
                "192.168.1.24": .failsBeforeTokens(
                    .refused(BrainRefusal(reason: .busy, retryAfterSeconds: 15))
                ),
            ]).transport(),
            onBrainUpdate: { _ in }
        )
        let answer = await collect(provider.generateStreaming(prompt: "hello"))
        #expect(answer.contains("busy") || answer.contains("its own turn"))
    }

    @Test func midStreamBreakAppendsANoteInsteadOfVanishing() async {
        let provider = HomeBrainProvider(
            brain: brain(), key: key,
            transport: ScriptedStreams(byHost: [
                "192.168.1.24": .breaksAfter(["partial answ"], .streamInterrupted("preempted")),
            ]).transport(),
            onBrainUpdate: { _ in }
        )
        let answer = await collect(provider.generateStreaming(prompt: "hello"))
        #expect(answer.hasPrefix("partial answ"))
        #expect(answer.contains("interrupted") || answer.contains("dropped"))
    }

    @Test func aMidStreamBreakDoesNotRetryAnotherHost() async {
        let provider = HomeBrainProvider(
            brain: brain(hosts: ["10.0.0.9", "192.168.1.24"]), key: key,
            transport: ScriptedStreams(byHost: [
                "10.0.0.9": .breaksAfter(["first"], .streamInterrupted("hangup")),
                "192.168.1.24": .tokens(["second"]),
            ]).transport(),
            onBrainUpdate: { _ in }
        )
        let answer = await collect(provider.generateStreaming(prompt: "hello"))
        #expect(!answer.contains("second"))
    }

    @Test func generateThrowsWhenNothingArrived() async {
        let provider = HomeBrainProvider(
            brain: brain(), key: key,
            transport: ScriptedStreams(byHost: [
                "192.168.1.24": .failsBeforeTokens(.unreachable("no route")),
            ]).transport(),
            onBrainUpdate: { _ in }
        )
        await #expect(throws: InferenceError.self) {
            _ = try await provider.generate(prompt: "hello")
        }
    }

    @Test func nameCarriesTheMacsName() {
        let provider = HomeBrainProvider(
            brain: brain(), key: key,
            transport: ScriptedStreams(byHost: [:]).transport(),
            onBrainUpdate: { _ in }
        )
        #expect(provider.name.contains("Studio"))
    }
}

struct PairedBrainStoreTests {
    private final class MemoryKeyStore: BrainKeyStoring, @unchecked Sendable {
        let lock = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
        func setKey(_ key: Data, identity: String) throws {
            lock.withLock { $0[identity] = key }
        }

        func key(identity: String) -> Data? {
            lock.withLock { $0[identity] }
        }

        func removeKey(identity: String) {
            lock.withLock { _ = $0.removeValue(forKey: identity) }
        }
    }

    private func makeStore() -> (PairedBrainStore, UserDefaults) {
        let suite = "brainlink-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PairedBrainStore(defaults: defaults, keys: MemoryKeyStore()), defaults)
    }

    @Test func saveLoadRoundTripsBrainAndCredential() throws {
        let (store, _) = makeStore()
        try store.save(brain(), key: key)
        #expect(store.load() == brain())
        #expect(store.credential() == PSKCredential(identity: "ID-1", key: key))
    }

    @Test func forgetRemovesEverything() throws {
        let (store, _) = makeStore()
        try store.save(brain(), key: key)
        store.forget()
        #expect(store.load() == nil)
        #expect(store.credential() == nil)
    }

    @Test func updateRewritesMetadataOnly() throws {
        let (store, _) = makeStore()
        try store.save(brain(), key: key)
        var updated = brain()
        updated.lastKnownHost = "10.0.0.5"
        store.update(updated)
        #expect(store.load()?.lastKnownHost == "10.0.0.5")
        #expect(store.credential()?.key == key)
    }

    @Test func emptyStoreLoadsNilNotJunk() {
        let (store, _) = makeStore()
        #expect(store.load() == nil)
        #expect(store.credential() == nil)
    }
}
