//
//  ModelCacheIntegrity.swift
//  M1K3MLX
//
//  The pre-load tripwire for a TORN model directory. On 2026-07-16 a load of a
//  partially-written cache dir (weights index promising shards the files
//  didn't back) reached mlx-swift's quantize pass, whose Module.update runs in
//  a non-throwing context — the thrown UpdateError became swift_unexpectedError
//  and took the WHOLE APP down (Quantized.swift:126 → Module.swift:598). The
//  loader cannot be taught to throw from our side, so the defence is upstream
//  of it: verify the directory BEFORE loadContainer, and treat torn state as
//  "delete and let HubApi re-download", never as a crash.
//
//  Deliberately narrow: only the states that actually reach the crashing path
//  count as torn (index references a missing or zero-byte shard; a zero-byte
//  safetensors). Resumable `.incomplete` partials under .cache are NOT torn —
//  HubApi resumes those legitimately. A directory with no weights at all is
//  .empty (the normal pre-download state). No-index-but-weights is .ok — a
//  single-file model without an index cannot be validated, and blocking it
//  would regress legacy caches.
//
//  Signed: Kev + claude-fable-5, 2026-07-16, Confidence 0.85 (the torn→crash
//  chain is stack-trace-evidenced; the verdict rules are pure and pinned; the
//  delete-then-redownload recovery is verify-by-launch). Prior: Unknown
//

import Foundation
import os

private let integrityLog = Logger(subsystem: "app.m1k3", category: "mlx-load")

/// Pure verdict over a model directory's weight files. IO lives in `scan`;
/// the decision is testable without a filesystem.
public enum ModelCacheIntegrity {
    public enum Verdict: Equatable, Sendable {
        /// Weights present and (where an index exists) accounted for.
        case ok
        /// No weight files — the normal state before a first download.
        case empty
        /// Missing shards WITH resumable `.incomplete` parts alongside — an
        /// interrupted download HubApi will resume. Never healed: deleting it
        /// would throw away gigabytes of healthy partial on every retry
        /// (review catch on the first cut of this file).
        case resuming
        /// The state that crashes the loader: partial weights on disk that
        /// HubApi believes are a COMPLETE snapshot (no resumable parts).
        case torn(reason: String)
    }

    /// The decision core. `indexWeightFiles`: shard filenames referenced by
    /// model.safetensors.index.json (empty when no index).
    /// `safetensorsSizes`: filename → byte size for every *.safetensors present.
    /// `hasResumableParts`: any `.incomplete` staged under `.cache/` — the
    /// downloader's own in-flight marker. NOTE deliberately narrow: bare
    /// `.metadata` files do NOT count (the 2026-07-16 poisoned pre-seed left
    /// exactly metadata-without-incomplete, and that state crashed the loader).
    public static func verdict(
        indexWeightFiles: Set<String>,
        safetensorsSizes: [String: Int],
        hasResumableParts: Bool = false
    ) -> Verdict {
        if let empty = safetensorsSizes.first(where: { $0.value == 0 }) {
            return .torn(reason: "zero-byte shard \(empty.key)")
        }
        if !indexWeightFiles.isEmpty {
            let missing = indexWeightFiles.subtracting(safetensorsSizes.keys)
            if !missing.isEmpty {
                // An index present with NO shards at all is a pre-download
                // artifact (config fetched first), not torn — nothing partial
                // to poison the loader; HubApi fetches the shards next.
                if safetensorsSizes.isEmpty { return .empty }
                // Missing shards beside in-flight parts = a download to resume,
                // not a corpse to bury.
                if hasResumableParts { return .resuming }
                return .torn(reason: "index references missing shard(s): \(missing.sorted().joined(separator: ", "))")
            }
            return .ok
        }
        return safetensorsSizes.isEmpty ? .empty : .ok
    }

    /// Disk scan → verdict for the model directory `loadContainer` will read.
    public static func scan(directory: URL) -> Verdict {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return .empty }
        var sizes: [String: Int] = [:]
        for name in names where name.hasSuffix(".safetensors") {
            let path = directory.appendingPathComponent(name).path
            let attributes = try? fm.attributesOfItem(atPath: path)
            sizes[name] = (attributes?[.size] as? Int) ?? 0
        }
        var indexed: Set<String> = []
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: indexURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weightMap = object["weight_map"] as? [String: String]
        {
            indexed = Set(weightMap.values)
        }
        return verdict(
            indexWeightFiles: indexed,
            safetensorsSizes: sizes,
            hasResumableParts: hasIncompleteParts(under: directory.appendingPathComponent(".cache"))
        )
    }

    /// Any `.incomplete` file under the downloader's `.cache` staging area —
    /// the marker that distinguishes "interrupted, resumable" from "believed
    /// complete but torn".
    private static func hasIncompleteParts(under cacheDir: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(
            at: cacheDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(".incomplete") {
            return true
        }
        return false
    }

    /// Where a torn directory is moved aside to. A sibling, so it is never on
    /// the load path, and a fixed name so quarantine can never accumulate more
    /// than one copy per model.
    public static func quarantineURL(for directory: URL) -> URL {
        directory
            .deletingLastPathComponent()
            .appendingPathComponent(".m1k3-quarantine")
            .appendingPathComponent(directory.lastPathComponent)
    }

    /// The recovery: when the directory `loadContainer` is about to read is
    /// torn, get it off the load path so HubApi re-downloads cleanly.
    ///
    /// ⚠️ It is MOVED ASIDE, not deleted, and the distinction is not
    /// fastidiousness. The original cut deleted the directory outright, which
    /// bets a user's entire multi-GB download on the re-download succeeding.
    /// (When this was written the weights ALSO lived in purge-eligible
    /// `Library/Caches` — that half of the rationale retired 2026-07-31 when
    /// ModelStoreLocation moved them to Application Support; the purger
    /// really did eat them, twice in one afternoon. The don't-bet-the-bytes
    /// argument stands on its own.) It also sat awkwardly
    /// beside `WeightIntegrity`'s tamper path, which refuses to destroy the
    /// files it rejects on the grounds that they are evidence: the accidental
    /// case was treated more harshly than the hostile one.
    ///
    /// Quarantine is bounded to one copy per model (a fixed sibling path, and
    /// any previous quarantine is replaced), and cleared by `reclaimQuarantine`
    /// once a good copy is verified in place. If the move fails — most likely
    /// genuinely out of disk — it falls back to deleting, because clearing the
    /// load path is what actually prevents the crash and must not be optional.
    @discardableResult
    public static func healBeforeLoad(directory: URL) -> Verdict {
        let result = scan(directory: directory)
        guard case let .torn(reason) = result else { return result }

        let quarantine = quarantineURL(for: directory)
        let fm = FileManager.default
        try? fm.removeItem(at: quarantine)
        try? fm.createDirectory(
            at: quarantine.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            try fm.moveItem(at: directory, to: quarantine)
            integrityLog.fault(
                """
                torn model cache at \(directory.lastPathComponent, privacy: .public) \
                (\(reason, privacy: .public)) — moved aside for a clean re-download \
                (the alternative is the quantize fatalError). The partial is kept until \
                a good copy lands.
                """
            )
        } catch {
            integrityLog.fault(
                """
                torn model cache at \(directory.lastPathComponent, privacy: .public) \
                (\(reason, privacy: .public)) — could not quarantine \
                (\(error.localizedDescription, privacy: .public)), deleting instead. \
                Clearing the load path is not optional.
                """
            )
            try? fm.removeItem(at: directory)
        }
        return result
    }

    /// Drop a model's quarantined partial. Called once a fresh copy has been
    /// verified in place, which is the only moment the old bytes are provably
    /// no longer worth keeping.
    public static func reclaimQuarantine(for directory: URL) {
        let quarantine = quarantineURL(for: directory)
        guard FileManager.default.fileExists(atPath: quarantine.path) else { return }
        integrityLog.notice(
            "reclaiming quarantined partial for \(directory.lastPathComponent, privacy: .public)"
        )
        try? FileManager.default.removeItem(at: quarantine)
    }
}
