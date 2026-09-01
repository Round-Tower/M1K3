//
//  WeightImport.swift
//  M1K3MLX
//
//  Lets a user who already has the weights on disk ("I already downloaded
//  these") hand them to M1K3 without a re-download — safely, because the
//  digests pinned in PinnedWeights.swift do not care where the bytes came
//  from. Verifying an arbitrary folder against the manifest is exactly as
//  rigorous as verifying a HubApi download: same manifest, same hashing
//  (`WeightIntegrityScan.observe`), same verdict core (`WeightIntegrity.
//  verdict`). Nothing here reimplements either.
//
//  ⚠️ ASYMMETRIC WITH THE DOWNLOAD PATH, ON PURPOSE. `WeightIntegrityScan.
//  enforce` treats an unpinned repo as `.unpinned` and lets it through — that
//  permissiveness exists so eval A/B overrides and spike checkpoints stay
//  loadable; pinning protects what we SHIP, not an allowlist of everything
//  loadable. Import gets no such carve-out: a download at least came from the
//  host we asked for (main-branch drift notwithstanding), but an imported
//  folder is bytes from anywhere the user's Finder can reach, with zero
//  provenance. Without a pin there is nothing to check those bytes against,
//  so importing an unpinned repo is refused outright rather than waved
//  through unverified.
//
//  THE METADATA WRITE IS THE WHOLE POINT, not a nicety. Copying verified
//  bytes into the cache and stopping there would BE the 2026-07-16 pre-seed
//  incident again: `HubFileDownloader.download` (swift-transformers'
//  HubApi.swift) decides whether to skip a file by reading
//  `<dir>/.cache/huggingface/download/<file>.metadata`, and a copy with no
//  metadata reads as a copy HubApi has never seen — the NEXT launch
//  re-downloads everything, worse than useless, which is exactly what
//  happened when the app's cache was pre-seeded with the CLI's own metadata
//  layout instead of HubApi's. `HubApi.writeDownloadMetadata` is called
//  directly here rather than reimplemented, so the on-disk format can never
//  drift from what `readDownloadMetadata` actually accepts. `pin.revision`
//  is true as the commit hash — these bytes were just proven to match that
//  exact revision — and the pinned sha256 is true as the etag for the files
//  that matter (the multi-GB LFS shards; `HubFileDownloader.download`
//  confirms an LFS etag by hashing the local file and comparing, which is
//  precisely the check these bytes already passed).
//
//  Signed: Kev + claude-opus-4-8, 2026-07-21, Confidence 0.85 (every
//  behaviour in the header is test-pinned against a real filesystem,
//  including a direct read-back through HubApi's OWN `readDownloadMetadata`
//  rather than trusting our own string-splitting; the atomic-install failure
//  path is exercised directly. Honest caveat: this is verify-by-launch like
//  everything else that touches HubApi's on-disk layout — no test here
//  drives an actual `HubApiDownloader.download` call against an imported
//  directory to confirm it skips the network, because that needs a live
//  network call this suite deliberately never makes). Prior: Unknown
//

import Foundation
import Hub
import os

private let importLog = Logger(subsystem: "app.m1k3", category: "weight-import")

public enum WeightImport {
    public enum Outcome: Equatable, Sendable {
        case installed(files: Int)
        case alreadyPresent
    }

    /// Where an import for `repoID` should land — the SAME place its own
    /// downloader would have put it, so the two paths can never drift apart
    /// (the drift rule this module follows throughout, per
    /// `HuggingFaceBridge.swift`'s header).
    ///
    /// ⚠️ The base is looked up per repo, not assumed. The first cut hardcoded
    /// `llmDefault`, which is right for the two brains and WRONG for the
    /// retrieval embedder: that one downloads through `embedderDefault`
    /// (Documents/huggingface, the preserved 2.x layout) and would have been
    /// installed into the Caches tree, where `MLXEmbeddingService` never
    /// looks. The import would have reported success and then the app would
    /// have re-downloaded the whole thing — the exact silent no-op this
    /// feature exists to prevent. Caught in review before it shipped.
    public static func defaultDestination(for repoID: String) -> URL {
        downloader(for: repoID).hub.localRepoLocation(Hub.Repo(id: repoID))
    }

    /// The downloader whose on-disk root `repoID` belongs under. Unpinned
    /// repos cannot be imported at all, so the `.llm` fallback is unreachable
    /// from `importWeights` — it exists so this stays total rather than
    /// force-unwrapping a manifest lookup.
    static func downloader(for repoID: String) -> HubApiDownloader {
        switch PinnedWeights.downloadBase(for: repoID) {
        case .embedder: HubApiDownloader.embedderDefault
        case .llm, nil: HubApiDownloader.llmDefault
        }
    }

    /// Verify `source` against the manifest pinned for `repoID`, and if it
    /// checks out, install it at `destination` with HubApi-compatible
    /// download metadata.
    public static func importWeights(
        from source: URL,
        repoID: String,
        into destination: URL
    ) throws -> Outcome {
        guard let pin = PinnedWeights.pin(for: repoID) else {
            throw WeightImportError.unpinned(repoID: repoID)
        }
        return try importWeights(from: source, pin: pin, repoID: repoID, into: destination)
    }

    /// Testable core: `pin` injected so this runs against fixtures without
    /// touching the shipped manifest — the same shape as
    /// `WeightIntegrityScan.enforce(directory:pin:repoID:)`.
    static func importWeights(
        from source: URL,
        pin: WeightIntegrity.Pin,
        repoID: String,
        into destination: URL
    ) throws -> Outcome {
        // Checked BEFORE touching `source` at all: a destination that
        // already holds a verified copy needs nothing further, and this
        // ordering is what makes re-running an import safe without
        // recopying gigabytes — the second call never even opens `source`.
        if verifiedAlready(directory: destination, pin: pin, repoID: repoID) {
            return .alreadyPresent
        }

        let (observed, unreadable) = WeightIntegrityScan.observe(directory: source, pin: pin)
        switch WeightIntegrity.verdict(pin: pin, observed: observed, unreadable: unreadable) {
        case .unpinned:
            // Unreachable in practice — the public entry point above already
            // refused an unpinned repoID before `pin` could be non-nil here.
            // Kept exhaustive rather than force-unwrapped so a future
            // refactor that adds another call site can't silently reopen the
            // unpinned-import hole this file exists to close.
            throw WeightImportError.unpinned(repoID: repoID)
        case let .incomplete(missing):
            // A partial import would create exactly the torn state
            // `ModelCacheIntegrity` exists to catch — refuse, copy nothing.
            throw WeightImportError.incomplete(repoID: repoID, missing: missing)
        case let .tampered(files):
            throw WeightTamperError(repoID: repoID, files: files)
        case let .unverifiable(files):
            throw WeightUnverifiableError(repoID: repoID, files: files)
        case .verified:
            let count = try install(pin: pin, source: source, repoID: repoID, destination: destination)
            importLog.notice(
                "imported \(repoID, privacy: .public) from \(source.path, privacy: .public) — \(count) files"
            )
            return .installed(files: count)
        }
    }

    // MARK: - Idempotency

    /// True when `directory` already verifies against `pin` — reuses
    /// `WeightIntegrityScan.isFullyPresentAndVerified` (the same receipt-aware,
    /// fully-present check `HubApiDownloader.download`'s #72 pre-network
    /// short-circuit now shares), so a previously imported (or previously
    /// downloaded) destination costs a stat, not a rehash.
    private static func verifiedAlready(directory: URL, pin: WeightIntegrity.Pin, repoID: String) -> Bool {
        WeightIntegrityScan.isFullyPresentAndVerified(directory: directory, pin: pin, repoID: repoID)
    }

    // MARK: - Install

    /// Copy every pinned file from `source` into a staging directory beside
    /// `destination`, write HubApi-compatible download metadata for each,
    /// then move staging into place as ONE atomic operation.
    ///
    /// Not `private`: exposed at module level so the atomicity contract is
    /// directly testable without first needing to defeat the verify gate
    /// above. A copy failure partway through must leave `destination` as it
    /// was — untouched if it was empty, or the previous good copy if one
    /// existed — never partial bytes, because a half-copied file reads back as
    /// `.tampered` on the very next load (mismatched bytes, present on disk),
    /// which would make our own import path the source of a false supply-chain
    /// accusation against itself. The commit into place is atomic (see
    /// `commitStaged`); everything before it happens in a sibling staging dir.
    ///
    /// Staging-then-move rather than copy-then-verify-then-commit: verifying
    /// a fresh copy would mean rehashing gigabytes we already hashed once at
    /// `source` moments ago, for a `copyItem` failure mode (mid-copy I/O
    /// error) that already throws on its own and is caught by the `defer`
    /// below.
    static func install(
        pin: WeightIntegrity.Pin,
        source: URL,
        repoID: String,
        destination: URL
    ) throws -> Int {
        let fm = FileManager.default
        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".m1k3-import-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for (name, expected) in pin.files {
            try fm.copyItem(
                at: source.appendingPathComponent(name),
                to: staging.appendingPathComponent(name)
            )
            // This particular call writes to an explicit path, so the hub it
            // hangs off does not change WHERE the metadata lands — but using
            // the repo's own downloader keeps that a fact rather than a
            // coincidence someone has to re-derive later.
            try downloader(for: repoID).hub.writeDownloadMetadata(
                commitHash: pin.revision,
                etag: expected.sha256,
                metadataPath: staging
                    .appendingPathComponent(".cache/huggingface/download")
                    .appendingPathComponent("\(name).metadata")
            )
        }

        try commitStaged(from: staging, to: destination)
        return pin.files.count
    }

    /// Atomically replace `destination` with `staging`.
    ///
    /// ⚠️ Move-aside → move-in → drop-aside, NOT remove-then-move. The first
    /// cut deleted the existing destination and only then moved staging in, so
    /// a move failure after the delete (disk-full, permissions, a cross-volume
    /// case) left the model with NO cache at all — worse than the "leaves no
    /// trace" contract, and on the very path built not to be the source of a
    /// false tamper verdict against itself. Now the old copy is set aside first
    /// and removed only once the new one is in place; if the move throws, the
    /// old copy goes back. `destination` is therefore only ever the previous
    /// good copy or the new verified one, never absent. Review catch.
    static func commitStaged(from staging: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let hadOld = fm.fileExists(atPath: destination.path)
        let aside = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".m1k3-replacing-\(UUID().uuidString)")
        if hadOld { try fm.moveItem(at: destination, to: aside) }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            // Put the previous copy back before surfacing the failure — the
            // replacement never arrived, so the old one is still the truth.
            if hadOld { try? fm.moveItem(at: aside, to: destination) }
            throw error
        }
        if hadOld { try? fm.removeItem(at: aside) }
    }
}

/// Thrown for the import-specific refusals that have no counterpart on the
/// download path — see this file's header for why the two are deliberately
/// asymmetric.
public enum WeightImportError: Error, CustomStringConvertible, Sendable, Equatable {
    /// No pin for this repo, so there is nothing to verify an imported
    /// folder against. Unlike a download (`WeightIntegrity.Verdict.unpinned`,
    /// deliberately permissive so eval overrides keep working), import
    /// refuses outright: an unpinned repo has no manifest at all, pinned or
    /// otherwise, to hold arbitrary bytes to.
    case unpinned(repoID: String)
    /// The source folder is missing pinned files. Nothing was copied — a
    /// partial import would leave the exact torn state `ModelCacheIntegrity`
    /// exists to catch.
    case incomplete(repoID: String, missing: [String])

    public var description: String {
        switch self {
        case let .unpinned(repoID):
            """
            Cannot import \(repoID): this build has no pinned manifest for it, so \
            there is nothing to verify an imported folder against. Unpinned repos \
            are only ever fetched fresh, never imported from an unverified folder.
            """
        case let .incomplete(repoID, missing):
            """
            Cannot import \(repoID): the source folder is missing \
            \(missing.joined(separator: ", ")). Nothing was copied — a partial \
            import would leave a torn cache behind.
            """
        }
    }
}
