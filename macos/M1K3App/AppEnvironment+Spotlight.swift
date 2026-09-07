//
//  AppEnvironment+Spotlight.swift
//  M1K3
//
//  Opt-in ⌘Space: donate document/call TITLES to the OS (CoreSpotlight) index.
//  The rules live in the pure, unit-pinned SpotlightDonorPolicy (M1K3Knowledge):
//  allowlist .document/.call only — never memories (title == fact text), never
//  .quarantined, never unknown kinds. Data-minimal: title + kind label + date;
//  no body text ever reaches the OS index.
//
//  Lifecycle doctrine (challenger-shaped, 2026-07-13):
//    - Default OFF (Phase 17a: nil is a NO). ON is a calm Settings opt-in.
//    - One idempotent reconcile owns every trigger (launch, toggle, thermal
//      recovery): ON → deleteAll + full re-donate; OFF → deleteAll,
//      UNCONDITIONALLY — the OS index survives container resets the store
//      doesn't, so OFF must actively enforce emptiness, not assume it.
//    - Donation is CSSearchableIndex only. Never NSUserActivity, never
//      public-indexing/Handoff eligibility — those are the only paths that
//      would take a title off this Mac.
//
//  Signed: Kev + claude-fable-5, 2026-07-13, Confidence 0.85 (policy layer is
//  unit-pinned; CSSearchableIndex behaviour — expiry pin, domain delete —
//  is verify-by-launch). Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-08 — the sync is skipped under the
//  screengrab harness: the CoreSpotlight domain is global, so a reconcile against
//  the sibling store would clobber the owner's real donations. Confidence now 0.85.
//

import CoreSpotlight
import Foundation
import M1K3Knowledge
import M1K3LogCore
import M1K3Screengrab
import OSLog

/// CSSearchableIndex adapter behind the pure `SystemSearchIndexing` seam.
final class SpotlightIndexer: SystemSearchIndexing {
    func donate(_ entries: [SearchIndexEntry]) async throws {
        guard CSSearchableIndex.isIndexingAvailable(), !entries.isEmpty else { return }
        let items = entries.map { entry in
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = entry.title
            attributes.contentDescription = "M1K3 \(entry.kindLabel.lowercased())"
            attributes.contentCreationDate = entry.createdAt
            let item = CSSearchableItem(
                uniqueIdentifier: entry.uniqueID,
                domainIdentifier: SpotlightDonorPolicy.domainIdentifier,
                attributeSet: attributes
            )
            // Spotlight silently expires items (~30 days) unless pinned. The
            // launch rebuild refreshes anyway; the pin covers Macs that just
            // sleep past the default expiry.
            item.expirationDate = .distantFuture
            return item
        }
        try await CSSearchableIndex.default().indexSearchableItems(items)
    }

    func deindex(uniqueIDs: [String]) async throws {
        guard !uniqueIDs.isEmpty else { return }
        try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: uniqueIDs)
    }

    func deleteAll() async throws {
        try await CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [SpotlightDonorPolicy.domainIdentifier])
    }
}

extension AppEnvironment {
    /// Settings toggle — absent/false means OFF (nil is a NO).
    nonisolated static let spotlightIndexingKey = "spotlight.indexingEnabled"

    private static let spotlightLog = M1K3Log.logger(.spotlight)

    var spotlightIndexingEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.spotlightIndexingKey)
    }

    /// One-shot flag for the calm Spotlight invite (shown once, ever).
    nonisolated static let spotlightTipShownKey = "spotlight.tipShown"

    /// The earned calm invite (the Phase 17a opt-in pattern): offered ONCE,
    /// on the ingest-status line right after the user adds a document — the
    /// moment the offer makes sense — and only while indexing is off. Never
    /// a modal, never repeated; the default stays OFF.
    func spotlightTipIfDue() -> String {
        let defaults = UserDefaults.standard
        guard !spotlightIndexingEnabled,
              !defaults.bool(forKey: Self.spotlightTipShownKey) else { return "" }
        defaults.set(true, forKey: Self.spotlightTipShownKey)
        return " Tip: M1K3 can make document titles findable in Spotlight — see Settings."
    }

    /// The one reconcile every trigger funnels through (launch, Settings
    /// toggle, thermal recovery). The state machine — latch, coalesce-rerun
    /// (a rapid ON→OFF toggle converges on the LAST state), OFF-before-
    /// thermal ordering, per-kind cap detection — is the unit-pinned
    /// `SpotlightReconciler` (M1K3Knowledge); this wrapper supplies live
    /// dependencies and maps outcomes to log lines.
    func syncSpotlightIndex() async {
        // The screengrab harness must never touch the system index: the domain
        // is global, so a reconcile against the sibling store would delete the
        // owner's real donations and donate the demo persona in their place.
        guard !ScreengrabHarness.current.isActive else {
            Self.spotlightLog.notice("spotlight sync skipped under the screengrab harness")
            return
        }
        let outcomes = await spotlightReconciler.sync(
            enabled: { self.spotlightIndexingEnabled },
            backgroundWorkAllowed: { Self.backgroundWorkAllowed() },
            fetch: { kind, limit in try self.store.allItems(kind: kind, limit: limit) }
        )
        for outcome in outcomes {
            switch outcome {
            case .cleared:
                Self.spotlightLog.notice("spotlight index cleared (indexing off)")
            case let .clearFailed(message):
                // The one failure that most needs a breadcrumb: opt-out must
                // empty the index, and a silent miss leaves titles in ⌘Space.
                Self.spotlightLog.error("spotlight opt-out deleteAll FAILED: \(message, privacy: .public)")
            case .deferredForHeat:
                armThermalRecovery()
            case let .reconciled(donated, capsHit):
                for label in capsHit {
                    Self.spotlightLog.error(
                        """
                        spotlight reconcile hit the \(SpotlightReconciler.fetchLimit, privacy: .public) \
                        \(label, privacy: .public) cap — older items are NOT donated
                        """
                    )
                }
                Self.spotlightLog.notice("spotlight reconciled: \(donated, privacy: .public) item(s) donated")
            case let .failed(message):
                Self.spotlightLog.error("spotlight reconcile failed: \(message, privacy: .public)")
            }
        }
    }

    /// Donate one freshly-ingested item (no-op when OFF or not donatable —
    /// the policy owns the kind rules).
    func spotlightDonate(itemID: UUID) async {
        guard spotlightIndexingEnabled else { return }
        // item(id:) has no kind filter by design — the policy is the filter here.
        guard let item = try? store.item(id: itemID),
              let entry = SpotlightDonorPolicy.entry(for: item) else { return }
        do {
            try await spotlightIndexer.donate([entry])
        } catch {
            Self.spotlightLog.error("spotlight donate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove one deleted item from the OS index. Runs regardless of the
    /// toggle — a deindex is always safe and a delete must never leave a ghost.
    func spotlightDeindex(id: UUID) async {
        do {
            try await spotlightIndexer.deindex(uniqueIDs: [SpotlightDonorPolicy.uniqueID(for: id)])
        } catch {
            Self.spotlightLog.error("spotlight deindex failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
