//
//  WeightImportDisplay.swift
//  M1K3MLX
//
//  Pure display-mapping for the "Import weights from a folder…" affordance
//  (the Advanced pane's section until 1.1 removed it; the mapping stays, tested). Two seams, both worth pinning without a filesystem
//  or a running app:
//
//    1. Which tiers even offer an import — Mini is Apple Foundation Models
//       (no `mlxModelID`, nothing on disk to point at), so it must never
//       appear in the picker. Getting this wrong silently offers an import
//       for a tier that can't use one.
//    2. How a `WeightImport.Outcome` (success) or the errors it can throw
//       (failure) read on screen. The errors' `description`s were written
//       deliberately (WeightImport.swift / WeightIntegrity.swift headers) —
//       this file surfaces them VERBATIM, never paraphrases. Three TYPED
//       overloads, not one generic `Error`-taking function — see the big
//       comment on `outcome(for: WeightImportError)` below for why a
//       generic `as? any CustomStringConvertible` cast is a Darwin trap
//       here (it always succeeds, even for a stranger `NSError`).
//
//  The view (AdvancedSettingsPane) is a thin switch over `Outcome` — no
//  string-building, no error-type matching, lives here instead where
//  swift-testing can pin it.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-21, Confidence 0.85 (every branch
//  test-pinned, including the typed-overload-vs-cast landmine, caught by a
//  failing test against the first cut before this file ever shipped).
//  Honest caveat: the copy itself ("won't re-download") is a judgement
//  call, not derived from anything — reasonable wording, not a spec.
//  Prior: Unknown
//

import Foundation
import M1K3Inference

/// Maps `WeightImport`'s outcomes and errors to what the (retired in 1.1) Advanced-pane import section showed.
public enum WeightImportDisplay {
    /// What the pane renders: a success line or a failure line. No "pending"
    /// case here — the view owns in-flight state (`AppEnvironment`'s
    /// `WeightImportRunState`), because that's app-lifecycle state, not a
    /// mapping of a *result* this type exists to describe.
    public enum Outcome: Equatable, Sendable {
        case success(message: String)
        case failure(message: String)
    }

    /// Tiers with weights worth importing — every MLX-backed tier. Mini
    /// (Apple Foundation Models) is excluded by construction: `mlxModelID`
    /// is nil for it, so there is no destination to verify a folder against.
    public static func importableTiers(from allCases: [BrainTier] = BrainTier.allCases) -> [BrainTier] {
        allCases.filter { $0.mlxModelID != nil }
    }

    /// Where a brain's weights currently sit, for the pane to surface — the
    /// natural other half of "import from a folder". Import is for when they
    /// are somewhere else; this is for when they are already here.
    public enum FolderStatus: Equatable, Sendable {
        /// On disk at `url` — offer to reveal it in Finder.
        case present(url: URL)
        /// Not downloaded yet, so there is nothing to show. The location where
        /// it WOULD land is deliberately not surfaced: revealing an empty or
        /// missing folder reads as "here are your weights" when there are none.
        case absent

        public var revealURL: URL? {
            switch self {
            case let .present(url): url
            case .absent: nil
            }
        }
    }

    /// Resolve the display status for a brain's current on-disk weights.
    /// `location` is where its files live (from `WeightImport.defaultDestination`,
    /// which is download-base-aware); `isInstalled` is whether the bytes are
    /// actually there. Only a genuinely present folder is revealable — a known
    /// location with no bytes is still `.absent`, so the pane never points a
    /// person at an empty directory.
    public static func folderStatus(isInstalled: Bool, location: URL?) -> FolderStatus {
        guard isInstalled, let location else { return .absent }
        return .present(url: location)
    }

    /// `.installed`/`.alreadyPresent` both read as success — `.alreadyPresent`
    /// is explicitly NOT an error (the spec's own framing: "say so plainly;
    /// this is a success, not an error").
    public static func outcome(for result: WeightImport.Outcome) -> Outcome {
        switch result {
        case let .installed(files):
            .success(message:
                "Imported \(files) file\(files == 1 ? "" : "s") — "
                    + "M1K3 won't re-download this model.")
        case .alreadyPresent:
            .success(message: "Already installed and verified — nothing to do.")
        }
    }

    /// The three error types `WeightImport.importWeights` can throw
    /// (`WeightImportError`, `WeightTamperError`, `WeightUnverifiableError`)
    /// each conform to `CustomStringConvertible` with copy written for
    /// exactly this surface — pass it through untouched.
    ///
    /// ⚠️ Deliberately THREE typed overloads instead of one generic
    /// `outcome(for error: Error)` that casts to `any CustomStringConvertible`.
    /// That cast is a Darwin landmine: EVERY `Error` bridges to `NSObject`
    /// at runtime (the `Error`→`NSError` bridge), and `NSObject` itself
    /// conforms to `CustomStringConvertible` — so `error as? any
    /// CustomStringConvertible` **always succeeds**, even for a bare
    /// `NSError` that never opted in, and hands back NSError's verbose
    /// `"Error Domain=… Code=… …UserInfo={…}"` dump instead of
    /// `localizedDescription`. Caught by
    /// `unknownErrorFallsBackToLocalizedDescription` failing against the
    /// first cut of this file. Matching the CONCRETE thrown type at the
    /// catch site (see `AppEnvironment+WeightImport.swift`) sidesteps the
    /// bridge entirely — only `outcome(unrecognized:)` ever sees
    /// `localizedDescription`, and only for a type that is genuinely none
    /// of the three below.
    public static func outcome(for error: WeightImportError) -> Outcome {
        .failure(message: error.description)
    }

    public static func outcome(for error: WeightTamperError) -> Outcome {
        .failure(message: error.description)
    }

    public static func outcome(for error: WeightUnverifiableError) -> Outcome {
        .failure(message: error.description)
    }

    /// Anything that isn't one of the three known thrown types — unreachable
    /// in practice (the throw site's signature is `any Error`, so the
    /// compiler can't statically rule this branch out, but every actual
    /// throw in `WeightImport.importWeights` is one of the three above).
    /// `localizedDescription`, not `description` — no bridge trap here since
    /// there's no cast, just Foundation's own error-message accessor.
    public static func outcome(unrecognized error: Error) -> Outcome {
        .failure(message: error.localizedDescription)
    }
}
