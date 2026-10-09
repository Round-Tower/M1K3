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

import Foundation
import M1K3Inference
import M1K3Knowledge
import Observation

@MainActor
@Observable
public final class PhotoMemory {
    public enum State: Equatable, Sendable {
        /// A caption is being written -- the visible "Looking..." state.
        case looking
        case remembered
        case failed(String)
    }

    private var transient: [String: State] = [:]
    private let providerSource: @MainActor () -> any InferenceProvider
    private let tierSource: @MainActor () -> BrainTier
    private let ingester: ImageCaptionIngester

    /// Fired after a remember or a forget changes the store, so the shell can
    /// refresh counts and lists.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    public init(
        provider: @escaping @MainActor () -> any InferenceProvider,
        tier: @escaping @MainActor () -> BrainTier,
        ingester: ImageCaptionIngester
    ) {
        providerSource = provider
        tierSource = tier
        self.ingester = ingester
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
        do {
            let caption = try await ImageCaptioner(provider: providerSource())
                .caption(image: image, tier: tierSource())
            try await ingester.ingest(caption: caption, attachmentFilename: key)
            transient[key] = .remembered
            onChange?()
        } catch {
            transient[key] = .failed(error.localizedDescription)
        }
    }

    /// The conversation-delete cascade. Returns how many Photo memories went.
    @discardableResult
    public func forget(_ images: [ImageAttachment]) -> Int {
        let names = images.map(Self.key)
        let removed = (try? ingester.forget(attachments: names)) ?? 0
        for name in names {
            transient[name] = nil
        }
        onChange?()
        return removed
    }
}
