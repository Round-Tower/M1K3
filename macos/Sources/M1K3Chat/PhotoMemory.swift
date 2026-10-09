//
//  PhotoMemory.swift
//  M1K3Chat
//
//  The model behind "Remember this photo", shared by the Mac and iOS shells so
//  the two cannot drift: row state per attachment, single-flight, the policy
//  check, caption -> ingest, and the forget cascade. All the rules live in
//  ImageCaptionPolicy / ImageCaptioner / ImageCaptionIngester; this only
//  sequences them and holds what a row needs to draw.
//
//  State is keyed on the attachment FILENAME (the knowledge sourceRef's key),
//  and "remembered" is read from the store, never cached across launches.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-09 (code-quality fold) — a success clears the transient
//  instead of caching `.remembered`, so a Photo deleted from the Documents list resets the row.
//  Review: Kev + claude-fable-5.1, 2026-10-09 (#523 second-pass fold) — `forget` no longer swallows a store
//  error on the privacy-forget path: it logs at `.error` (chat-session), returns 0, and leaves the row
//  reading the store (still remembered — honest). `forgetter:` is the test seam for a refusing store.
//  Review: Kev + claude-fable-5.1, 2026-10-09 (#523 third-pass fold) — `forget` during an in-flight caption
//  used to let the ingest land afterwards: an orphan Photo nothing could cascade-delete. `forgotten` marks the
//  in-flight keys; `remember` skips the ingest (or forgets a landed one), resets the row, logs once. A cancelled
//  remember resets the row to nil instead of `.failed("cancelled")`.

import Foundation
import M1K3Inference
import M1K3Knowledge
import M1K3LogCore
import Observation
import os

@MainActor
@Observable
public final class PhotoMemory {
    public enum State: Equatable, Sendable {
        /// A caption is being written -- the visible "Looking..." state.
        case looking
        case remembered
        case failed(String)
    }

    private static let log = M1K3Log.logger(.chatSession)

    private var transient: [String: State] = [:]
    /// Keys `forget` saw while their caption was in flight. `remember` consumes
    /// its own key after the awaits so the ingest never outlives the delete.
    private var forgotten: Set<String> = []
    private let providerSource: @MainActor () -> any InferenceProvider
    private let tierSource: @MainActor () -> BrainTier
    private let ingester: ImageCaptionIngester
    /// The forget cascade's store call — `ingester.forget(attachments:)` in
    /// production; a refusing double in the failure-path test.
    private let forgetter: ([String]) throws -> Int

    /// Fired after a remember or a forget changes the store, so the shell can
    /// refresh counts and lists.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public convenience init(
        provider: @escaping @MainActor () -> any InferenceProvider,
        tier: @escaping @MainActor () -> BrainTier,
        ingester: ImageCaptionIngester
    ) {
        self.init(provider: provider, tier: tier, ingester: ingester, forgetter: ingester.forget(attachments:))
    }

    init(
        provider: @escaping @MainActor () -> any InferenceProvider,
        tier: @escaping @MainActor () -> BrainTier,
        ingester: ImageCaptionIngester,
        forgetter: @escaping ([String]) throws -> Int
    ) {
        providerSource = provider
        tierSource = tier
        self.ingester = ingester
        self.forgetter = forgetter
    }

    private static func key(_ image: ImageAttachment) -> String {
        image.url.lastPathComponent
    }

    /// nil = never asked and not stored; the row shows the plain action.
    public func state(for image: ImageAttachment) -> State? {
        let key = Self.key(image)
        if let current = transient[key] { return current }
        return ingester.isRemembered(attachment: key) ? .remembered : nil
    }

    /// The user's tap. No-op while looking or once remembered.
    public func remember(_ image: ImageAttachment) async {
        let key = Self.key(image)
        switch state(for: image) {
        case .looking, .remembered: return
        case .failed, nil: break
        }
        transient[key] = .looking
        forgotten.remove(key)
        do {
            let caption = try await ImageCaptioner(provider: providerSource())
                .caption(image: image, tier: tierSource())
            // The conversation went while we were looking: the files are gone,
            // so an ingest now would write a Photo nothing can cascade-delete.
            guard !forgotten.contains(key) else {
                try discardForgotten(key, landed: false)
                return
            }
            try await ingester.ingest(caption: caption, attachmentFilename: key)
            guard !forgotten.contains(key) else {
                try discardForgotten(key, landed: true)
                return
            }
            // Cleared, not cached: `state(for:)` reads "remembered" from the store,
            // so a Photo deleted from the Documents list shows the action again.
            transient[key] = nil
            onChange?()
        } catch is CancellationError {
            // Not a failure to show: the row goes back to the plain action.
            transient[key] = nil
        } catch {
            transient[key] = .failed(error.localizedDescription)
        }
    }

    /// `forget` raced this remember. A landed ingest is deleted through the
    /// same forgetter as the cascade; either way the row resets and we log once.
    private func discardForgotten(_ key: String, landed: Bool) throws {
        forgotten.remove(key)
        transient[key] = nil
        Self.log.notice("photo forgotten while captioning, ingest \(landed ? "deleted" : "skipped", privacy: .public)")
        if landed {
            _ = try forgetter([key])
            onChange?()
        }
    }

    /// The conversation-delete cascade. Returns how many Photo memories went.
    /// A store refusal is a privacy failure (the image files are already gone,
    /// the caption would linger): it is logged, 0 is returned, and the
    /// transient is left alone so `state(for:)` keeps reading the store —
    /// which still says remembered. The shell is notified either way.
    @discardableResult
    public func forget(_ images: [ImageAttachment]) -> Int {
        let names = images.map(Self.key)
        for name in names where transient[name] == .looking {
            forgotten.insert(name)
        }
        var removed = 0
        do {
            removed = try forgetter(names)
            for name in names {
                transient[name] = nil
            }
        } catch {
            let count = names.count
            let reason = error.localizedDescription
            Self.log.error("photo forget failed, \(count, privacy: .public) attachment(s): \(reason, privacy: .public)")
        }
        onChange?()
        return removed
    }
}
