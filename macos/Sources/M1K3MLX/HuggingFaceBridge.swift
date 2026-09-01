//
//  HuggingFaceBridge.swift
//  M1K3MLX
//
//  mlx-swift-lm 3.x removed its built-in HuggingFace client: loading takes
//  `any Downloader` + `any TokenizerLoader`. The official adapter packages
//  (DePasqualeOrg swift-tokenizers-mlx / swift-hf-api-mlx) are NOT usable here
//  — their `swift-tokenizers` declares a target literally named `Tokenizers`,
//  colliding with WhisperKit's `swift-transformers` target of the same name
//  (probe-verified: "conflicting name: 'Tokenizers'"). So M1K3 bridges the two
//  small protocols to swift-transformers directly — the same library WhisperKit
//  already pins, and the same HubApi the 2.x line used internally, so the
//  existing downloaded weights are reused byte-for-byte:
//
//    LLM weights      → Library/Application Support/models/<id>
//                       (Caches until 2026-07-31 — purge-eligible, and macOS
//                        really did purge the brains; ModelStoreLocation
//                        migrates surviving Caches bytes across)
//    embedder weights → Documents/huggingface/models/<id> (2.x HubApi())
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.8 (bridge compiles +
//  mirrors 2.30.6's own Load.swift glue incl. the offline/auth fallbacks; the
//  download path is verify-by-launch). Prior: Unknown.
//

import Foundation
import Hub
import M1K3Inference
import MLXLMCommon
import os
import Synchronization
import Tokenizers

/// Multi-GB model fetches were a silent progress fraction — this category says
/// which model is downloading, how far along, how big on disk, and an ETA.
///   log stream --predicate 'subsystem == "app.m1k3" AND category == "model-download"'
private let downloadLog = Logger(subsystem: "app.m1k3", category: "model-download")

/// Decides which download progress updates become log lines: the first, the
/// last, every 5% of progress, or every 10s of wall clock — whichever first.
/// (HubApi's Progress is FILE-weighted, so the fraction jumps per file; the
/// time floor keeps a single huge safetensors file from going silent.)
struct DownloadLogThrottle {
    private var lastFraction: Double?
    private var lastEmit: ContinuousClock.Instant?

    mutating func shouldEmit(fraction: Double, now: ContinuousClock.Instant) -> Bool {
        guard let lastFraction, let lastEmit else {
            lastFraction = fraction
            lastEmit = now
            return true
        }
        let stepped = fraction - lastFraction >= 0.05
        let stale = now - lastEmit >= .seconds(10)
        let finished = fraction >= 1.0 && lastFraction < 1.0
        guard stepped || stale || finished else { return false }
        self.lastFraction = fraction
        self.lastEmit = now
        return true
    }
}

/// One entry of the HF `/api/models/{id}/tree/{revision}` listing.
struct RepoTreeEntry: Decodable, Equatable {
    let type: String
    let size: Int
    let path: String
}

/// Expected byte total for the files a snapshot will actually fetch — the
/// basis for HONEST progress. HubApi's own Progress is file-weighted (one
/// huge safetensors pins the bar at "25%" for minutes); bytes-on-disk over
/// bytes-expected is what a download bar should show.
enum RepoSizeEstimate {
    /// Sum of file sizes matching the loader's glob patterns; nil when no
    /// entry matches (no basis for an estimate — caller falls back).
    static func expectedBytes(entries: [RepoTreeEntry], matching patterns: [String]) -> Int? {
        let matched = entries.filter { entry in
            entry.type == "file" && patterns.contains { pattern in
                matches(filename: (entry.path as NSString).lastPathComponent, pattern: pattern)
            }
        }
        guard !matched.isEmpty else { return nil }
        return matched.reduce(0) { $0 + $1.size }
    }

    /// `*`/`?` glob match, same shape HubApi applies to its file patterns.
    static func matches(filename: String, pattern: String) -> Bool {
        NSPredicate(format: "SELF LIKE %@", pattern).evaluate(with: filename)
    }

    /// Fetch the repo tree. Best-effort: any failure (offline, 404, schema
    /// drift) returns nil and progress falls back to the file-weighted kind.
    static func fetchEntries(repoID: String, revision: String) async -> [RepoTreeEntry]? {
        let encodedRevision = revision.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? revision
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/\(encodedRevision)") else {
            return nil
        }
        // Short fuse: this fires BEFORE the snapshot download, so on the
        // offline/auth-fallback path every second here is added launch
        // latency for a purely cosmetic (progress-bar) win.
        let request = URLRequest(url: url, timeoutInterval: 3)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode([RepoTreeEntry].self, from: data)
    }
}

/// `MLXLMCommon.Downloader` over swift-transformers' `HubApi`. Mirrors the
/// snapshot + offline-fallback behaviour of mlx-swift-lm 2.x's `downloadModel`.
struct HubApiDownloader: MLXLMCommon.Downloader {
    let hub: HubApi

    /// LLM weights base: Application Support since 2026-07-31 — the 2.x
    /// Caches default was purge-eligible and macOS DID purge multi-GB brains
    /// under disk pressure (twice in one afternoon, log-evidenced). PURE path
    /// resolution only: the one-time migration/exclusion runs via the app's
    /// explicit ModelStoreLocation.prepareOnce() — a static-let with
    /// filesystem side effects would fire under UNSANDBOXED `swift test` and
    /// mutate the host's real ~/Library (PR #92 review).
    static let llmDefault = HubApiDownloader(
        hub: HubApi(downloadBase: ModelStoreLocation.llmBase())
    )

    /// Downloads where 2.x's `MLXEmbedders.loadModelContainer` default put
    /// embedder weights (Documents/huggingface).
    static let embedderDefault = HubApiDownloader(hub: HubApi())

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let repo = Hub.Repo(id: id)
        let localPath = hub.localRepoLocation(repo)
        let startSizeMB = Self.directorySizeMB(localPath)

        // #72 item 1: when the caller does not want a refresh and the cache
        // already verifies fully against the pinned manifest, the network
        // round-trip has nothing to offer — the revision is a pinned commit
        // hash, so there is nothing newer to discover. Skipping it here means
        // a captive portal, DNS blip, or Hub 5xx never blocks a load whose
        // verified bytes are already sitting on disk. An unpinned repo has no
        // completeness oracle (nothing to check "fully present" against), so
        // it always falls through to the network exactly as before.
        if Self.shouldSkipNetworkFetch(
            useLatest: useLatest, directory: localPath, pin: PinnedWeights.pin(for: id), repoID: id
        ) {
            downloadLog.notice(
                "useLatest=false and \(id, privacy: .public) already verified locally (localMB=\(startSizeMB)) — skipping network"
            )
            return localPath
        }

        // Resolve to the PINNED commit for anything we ship — the pin beats the
        // caller, deliberately. mlx-swift-lm's `resolve` passes a revision
        // EXPLICITLY (defaulting to the literal "main"), so honouring callers
        // here would mean honouring that default, i.e. no pin at all on every
        // real load path. See WeightIntegrity.resolveRevision.
        let resolvedRevision = WeightIntegrity.resolveRevision(
            requested: revision,
            pin: PinnedWeights.pin(for: id)
        )
        downloadLog.notice(
            "snapshot start: \(id, privacy: .public) rev=\(resolvedRevision, privacy: .public) localMB=\(startSizeMB)"
        )
        let clock = ContinuousClock()
        let started = clock.now
        let throttle = Mutex(DownloadLogThrottle())
        let rateState = Mutex<(sizeMB: Int, at: ContinuousClock.Instant)>((startSizeMB, started))

        // Expected byte total from the repo tree (best-effort) — the basis for
        // an HONEST progress bar. HubApi's own fraction is file-weighted, so
        // onboarding sat at "25%" for minutes while one safetensors streamed.
        let expectedBytes = await RepoSizeEstimate.fetchEntries(repoID: id, revision: resolvedRevision)
            .flatMap { RepoSizeEstimate.expectedBytes(entries: $0, matching: patterns) }
        if let expectedBytes {
            let expectedMB = expectedBytes / 1_048_576
            downloadLog.notice("expected size: \(id, privacy: .public) \(expectedMB)MB")
        } else {
            downloadLog.notice("no size estimate for \(id, privacy: .public) — file-weighted progress")
        }
        // UI rescan cadence: ~2Hz disk-size checks, far cheaper than the
        // callback rate, smooth enough for a bar.
        let scanState = Mutex<(at: ContinuousClock.Instant, bytes: Int)?>(nil)

        do {
            let url = try await hub.snapshot(
                from: repo,
                revision: resolvedRevision,
                matching: patterns,
                progressHandler: { progress in
                    let fraction = progress.fractionCompleted
                    let now = clock.now

                    var forwarded = progress
                    if let expectedBytes {
                        let bytes = Self.throttledDiskBytes(at: localPath, now: now, state: scanState)
                        let synthesized = Progress(totalUnitCount: Int64(expectedBytes))
                        synthesized.completedUnitCount = Int64(min(bytes, expectedBytes))
                        forwarded = synthesized
                    }

                    if throttle.withLock({ $0.shouldEmit(fraction: fraction, now: now) }) {
                        let sizeMB = Self.directorySizeMB(localPath)
                        let previous = rateState.withLock { state in
                            let prior = state
                            state = (sizeMB, now)
                            return prior
                        }
                        let seconds = (now - previous.at).components.seconds
                        let rate = seconds > 0 ? (sizeMB - previous.sizeMB) / Int(seconds) : 0
                        Self.logProgress(
                            id: id, fraction: forwarded.fractionCompleted, elapsed: now - started,
                            sizeMB: sizeMB, rateMBps: rate, byteAccurate: expectedBytes != nil
                        )
                    }
                    progressHandler(forwarded)
                }
            )
            let totalSeconds = Int((clock.now - started).components.seconds)
            let sizeMB = Self.directorySizeMB(url)
            downloadLog.notice(
                "snapshot done: \(id, privacy: .public) in \(totalSeconds)s sizeMB=\(sizeMB)"
            )
            // Heal the known-stale gemma-4 chat template BEFORE judging the
            // directory — the manifest pins the healed bytes (Gemma4TemplateFix
            // header has the ordering rationale). Exact-hash-gated; a no-op
            // for every other repo and any unrecognised template.
            try Gemma4TemplateFix.apply(directory: url, repoID: id)
            // Supply-chain tripwire: check the bytes against the digests pinned
            // in this build BEFORE any factory reads a tensor. This is the one
            // window where refusal actually prevents a poisoned load. Throws
            // only WeightTamperError, which is not a transient network error,
            // so `withRetry` fails the load instead of spinning on it.
            try WeightIntegrityScan.enforce(directory: url, repoID: id)
            return url
        } catch Hub.HubClientError.authorizationRequired {
            // Typically "repo doesn't exist on the server" — fall back to any
            // local copy (same behaviour as 2.x).
            downloadLog.warning(
                "snapshot auth-required for \(id, privacy: .public) — using local copy (localMB=\(startSizeMB))"
            )
            // The fallbacks are verified too: a cache poisoned on an earlier
            // run must not become trusted just because we're offline now.
            try Gemma4TemplateFix.apply(directory: localPath, repoID: id)
            try WeightIntegrityScan.enforce(directory: localPath, repoID: id)
            return localPath
        } catch let error as WeightTamperError {
            // Never swallowed by the network-error handling below.
            throw error
        } catch {
            // #72 item 2: broadened beyond true offline. A timeout, DNS
            // failure, or Hub 5xx looks nothing like NSURLErrorNotConnected-
            // ToInternet, so the ORIGINAL narrow check here let 11 GB of
            // verified weights sit unusable through a captive portal or a
            // momentary Hub outage — the exact class `RetryPolicy.
            // isTransientNetworkError` already burned 3 attempts on
            // upstream (`withRetry`, the Gemma path) before this ever fires.
            if Self.isFallbackWorthy(error) {
                let reason = error.localizedDescription
                downloadLog.warning(
                    "network trouble (\(reason, privacy: .public)) for \(id, privacy: .public) — using local copy (localMB=\(startSizeMB))"
                )
                try Gemma4TemplateFix.apply(directory: localPath, repoID: id)
                try WeightIntegrityScan.enforce(directory: localPath, repoID: id)
                return localPath
            }
            let reason = error.localizedDescription
            downloadLog.error(
                "snapshot failed: \(id, privacy: .public) — \(reason, privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - #72: pre-network local-verification decisions

    /// Whether `download` can skip the network entirely and hand back
    /// `directory` as-is: the caller does not want a refresh AND `pin` is
    /// non-nil AND every pinned file already verifies on disk. `pin` is a
    /// parameter rather than a `PinnedWeights` lookup so this is directly
    /// testable against fixtures without touching the shipped manifest —
    /// the same shape as `WeightIntegrityScan.enforce(directory:pin:repoID:)`.
    /// An unpinned repo (`pin == nil`) has no completeness oracle at all, so
    /// it always falls through to the network, same as today.
    static func shouldSkipNetworkFetch(
        useLatest: Bool,
        directory: URL,
        pin: WeightIntegrity.Pin?,
        repoID: String
    ) -> Bool {
        guard !useLatest, let pin else { return false }
        return WeightIntegrityScan.isFullyPresentAndVerified(directory: directory, pin: pin, repoID: repoID)
    }

    /// Errors worth falling back to a verified local copy for (#72 item 2) —
    /// broader than the original "true offline" check. A timeout, DNS blip,
    /// or a Hub 5xx is indistinguishable from offline from the load's own
    /// perspective, and reaching here at all means any upstream retry policy
    /// has already exhausted its attempts on exactly this class — falling
    /// back to verified bytes beats surfacing the raw failure. A Hub 4xx
    /// (bad request, repo truly missing) is deliberately EXCLUDED: that is a
    /// real problem, not a transient one, and `authorizationRequired` already
    /// has its own dedicated catch clause above this one.
    static func isFallbackWorthy(_ error: Error) -> Bool {
        if RetryPolicy.isTransientNetworkError(error) { return true }
        if case let Hub.HubClientError.httpStatusCode(code) = error {
            return (500 ..< 600).contains(code)
        }
        return false
    }

    /// One throttled progress line: byte-accurate percent when the tree gave
    /// us an estimate, the file-weighted `files≈` fallback otherwise; plus the
    /// on-disk MB + measured MB/s either way.
    private static func logProgress(
        id: String, fraction: Double, elapsed: Duration, sizeMB: Int, rateMBps: Int,
        byteAccurate: Bool
    ) {
        let percent = Int(fraction * 100)
        let label = byteAccurate ? "" : "files≈"
        let elapsedSeconds = Int(elapsed.components.seconds)
        downloadLog.notice(
            "\(id, privacy: .public): \(label, privacy: .public)\(percent)% onDiskMB=\(sizeMB) rate=\(rateMBps)MB/s elapsed=\(elapsedSeconds)s"
        )
    }

    /// On-disk byte count, rescanned at most twice a second — the progress
    /// callback fires far more often than a bar needs.
    private static func throttledDiskBytes(
        at url: URL,
        now: ContinuousClock.Instant,
        state: borrowing Mutex<(at: ContinuousClock.Instant, bytes: Int)?>
    ) -> Int {
        let cached = state.withLock { $0 }
        if let cached, now - cached.at < .milliseconds(500) {
            return cached.bytes
        }
        let bytes = directorySizeBytes(url)
        state.withLock { $0 = (now, bytes) }
        return bytes
    }

    private static func directorySizeMB(_ url: URL) -> Int {
        directorySizeBytes(url) / 1_048_576
    }

    /// Recursive on-disk size — model repos are ~a dozen files, so this is a
    /// handful of stats, cheap enough at the throttled scan rate.
    private static func directorySizeBytes(_ url: URL) -> Int {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
        }
        return total
    }
}

/// `MLXLMCommon.TokenizerLoader` over swift-transformers' `AutoTokenizer`.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerAdapter(upstream: upstream)
    }
}

/// Adapts a swift-transformers tokenizer to `MLXLMCommon.Tokenizer`.
/// `@unchecked Sendable`: the upstream tokenizer is immutable after load and
/// only read concurrently (same contract WhisperKit relies on).
struct TransformersTokenizerAdapter: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? {
        upstream.bosToken
    }

    var eosToken: String? {
        upstream.eosToken
    }

    var unknownToken: String? {
        upstream.unknownToken
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(
            messages: messages,
            tools: tools,
            additionalContext: additionalContext
        )
    }
}
