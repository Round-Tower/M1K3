//
//  WeightIntegrity.swift
//  M1K3MLX
//
//  Supply-chain tripwire for downloaded model weights. Every brain M1K3 runs
//  is fetched at runtime from a third-party host (HuggingFace), and until this
//  file existed we fetched `main` — whatever that pointed at, whenever the
//  user happened to onboard — and handed the bytes straight to MLX. A bad day
//  upstream (host compromise, a hijacked org account, a force-pushed repo)
//  meant arbitrary weights executing on the user's machine with no tripwire.
//
//  The defence is two-part and both parts are needed:
//    1. PIN A REVISION, so "what we ship" stops being a moving target. Note
//       this also turns a real, already-observed behaviour into an explicit
//       one: upstream repos change under us (the 2026-07-09 gemma chat-template
//       fix was expected to arrive purely via a weights re-pull, with no code
//       change and no review on our side). Pinning makes that a decision.
//    2. VERIFY THE BYTES against digests committed to THIS repo. Fetching the
//       expected hash from the same host that serves the file proves nothing —
//       whoever can swap the file can swap its published hash. The manifest
//       must travel with our source, signed and reviewed, or it is theatre.
//
//  ⚠️ The verdicts are deliberately NOT symmetric with ModelCacheIntegrity's,
//  and the difference is the point. A TORN cache is an accident, so it heals
//  silently: delete, re-download, carry on. TAMPERING is not an accident, so
//  it must NEVER auto-heal — silently re-fetching from the same poisoned
//  source would spin an infinite re-download loop that hides an active attack
//  behind what looks like flaky networking. Tampering refuses, loudly, and
//  the error is deliberately not retryable (`withRetry`'s default
//  `isTransientNetworkError` won't match it, so the load fails to
//  `AppReadiness.failed` instead of looping).
//
//  The other asymmetry that matters: an ABSENT pinned file is NOT tampering.
//  Mid-download, most files are absent — that is the overwhelmingly common
//  case, and treating it as an attack would alarm on every first run. Absent
//  is `.incomplete`; present-but-wrong is `.tampered`.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-21, Confidence 0.9 (the verdict
//  rules are pure and exhaustively pinned; the shipped manifest's digests were
//  computed from the on-disk snapshots that produced the 2026-07-15/16 eval
//  results AND independently agree with HuggingFace's published LFS oids for
//  all five large files — two parties confirming the same bytes). Honest
//  caveat: the refuse-on-tamper path is verify-by-launch like every MLX path
//  here, and pinning is bootstrapped from bytes we already trusted, which is
//  the irreducible trust-on-first-use step every pinning scheme has.
//  Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-11 — the three refusal errors conform to
//  `LocalizedError` (text unchanged), so a Settings row shows the sentence, not "The
//  operation couldn't be completed". Their `DownloadFailureClassifying` conformance (short
//  user copy, never transient) lives in DownloadErrors.swift. Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — `Pin.restricted(toFilesMatching:)`: the files a download's patterns
//  fetch. The verdict rules are unchanged; a file no pattern fetches is never loaded, so cutting it judges nothing
//  less. Confidence 0.9.
//

import Foundation

/// Pure trust verdict over a model directory, against a manifest pinned in
/// our own source. IO (hashing, disk walking) lives in `WeightIntegrityScan`;
/// the decision is testable without a filesystem or a network.
public enum WeightIntegrity {
    /// One pinned file: the size is a cheap pre-filter (a disagreement is
    /// already conclusive, no hashing required) and the digest is the proof.
    public struct PinnedFile: Equatable, Sendable {
        public let size: Int
        public let sha256: String

        public init(size: Int, sha256: String) {
            self.size = size
            self.sha256 = sha256
        }
    }

    /// Which on-disk root a repo's files belong under.
    ///
    /// These genuinely diverge, for a reason worth not "tidying up": the 2.x
    /// layout is preserved byte-for-byte so existing caches keep working (see
    /// `HuggingFaceBridge`'s header). LLM weights sit under Caches, embedder
    /// weights under Documents/huggingface. Anything that installs files
    /// therefore has to know which — assuming one base for everything puts the
    /// embedder where its loader never looks, which reads as a silent no-op
    /// and then re-downloads the whole thing.
    public enum DownloadBase: String, Equatable, Sendable {
        case llm
        case embedder
    }

    /// A repo pinned to one immutable commit plus the digests of the files we
    /// actually download from it.
    public struct Pin: Equatable, Sendable {
        /// Full 40-char commit SHA — never a branch name. A branch is exactly
        /// the moving target this type exists to remove.
        public let revision: String
        public let files: [String: PinnedFile]

        public init(revision: String, files: [String: PinnedFile]) {
            self.revision = revision
            self.files = files
        }

        /// The pinned files a download matching `patterns` fetches, at the same revision. Hub
        /// matches with `fnmatch(pattern, path, 0)` on the repo-relative path (`*` crosses `/`,
        /// case-sensitive), and so does this. A pinned file outside every pattern never arrives:
        /// the embedder's README.md, pinned from an `hf download` snapshot (#547).
        public func restricted(toFilesMatching patterns: [String]) -> Pin {
            Pin(revision: revision, files: files.filter { name, _ in
                patterns.contains { fnmatch($0, name, 0) == 0 }
            })
        }
    }

    public struct ObservedFile: Equatable, Sendable {
        public let size: Int
        public let sha256: String

        public init(size: Int, sha256: String) {
            self.size = size
            self.sha256 = sha256
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// No manifest entry for this repo. Deliberately permissive: eval
        /// A/B overrides and the spike checkpoints must stay loadable, and
        /// refusing every unpinned repo would make the instrument unusable.
        /// Pinning protects what we SHIP; it is not an allowlist.
        case unpinned
        /// Every pinned file is present and its bytes are the expected bytes.
        case verified
        /// Pinned files not on disk yet — a download in progress, benign.
        case incomplete(missing: [String])
        /// Files present that could NOT be read or hashed. Not an accusation,
        /// but not a pass either: we do not know what these bytes are, so the
        /// load must fail closed rather than proceed on an unchecked file.
        case unverifiable(files: [String])
        /// Files present whose bytes disagree with the manifest. Refuse.
        case tampered(files: [String])
    }

    /// Which revision a fetch of `repoID` must resolve against.
    ///
    /// ⚠️ THE PIN WINS OVER THE CALLER, and that precedence is the whole point.
    /// The first cut had this the other way around (`requested ?? pin`), which
    /// security review showed was dead code on every real load: mlx-swift-lm's
    /// `resolve` passes `configuration.id`'s revision EXPLICITLY, and
    /// `ModelConfiguration.Identifier.id` defaults it to the literal `"main"`
    /// rather than nil. So the caller was never nil in production, the pin was
    /// never consulted, and only `BrainWeightsFetcher`'s background pre-stage
    /// (the sole nil-passing caller) honoured it. Every actual model load still
    /// tracked a moving branch.
    ///
    /// A consequence worth stating plainly: an explicit revision for a PINNED
    /// repo is ignored. That is correct — "main" from a third-party default
    /// parameter is indistinguishable from a deliberate request, so honouring
    /// callers means honouring the SDK's default, which means no pin at all.
    /// Shipping different weights is a manifest change, by design.
    public static func resolveRevision(requested: String?, pin: Pin?) -> String {
        if let pin { return pin.revision }
        return requested ?? "main"
    }

    /// What a receipt attests to for one file. Size alone is not enough: a
    /// shard re-fetched from a compromised host is very likely to be the SAME
    /// size (tensor shapes and quantisation all but fix it), so the receipt
    /// must record something that moves when the file is rewritten.
    public struct FileStamp: Equatable, Sendable, Codable {
        public let size: Int
        /// Modification time, seconds since the reference date. A re-download
        /// always bumps this, which forces a rehash.
        public let modified: Double

        public init(size: Int, modified: Double) {
            self.size = size
            self.modified = modified
        }
    }

    /// Persisted proof that a directory's bytes were hashed and matched, so
    /// the multi-GB hash is paid at acquisition rather than on every launch.
    public struct Receipt: Equatable, Sendable, Codable {
        public let revision: String
        public let files: [String: FileStamp]

        public init(revision: String, files: [String: FileStamp]) {
            self.revision = revision
            self.files = files
        }
    }

    /// Whether `receipt` still vouches for what is on disk.
    ///
    /// Every pinned file must be present, at the pinned size, and unchanged
    /// since the receipt was written. The last clause is what security review
    /// found missing: the first cut compared the receipt's revision and sizes
    /// against the pin's own constants — a source constant compared to itself,
    /// which could never disagree — so a same-size file re-fetched from a
    /// compromised host after the first verified run was trusted forever
    /// without being hashed again.
    public static func receiptStillValid(
        receipt: Receipt,
        pin: Pin,
        observed: [String: FileStamp]
    ) -> Bool {
        guard receipt.revision == pin.revision else { return false }
        for (name, expected) in pin.files {
            guard
                let attested = receipt.files[name],
                let actual = observed[name],
                attested.size == expected.size,
                actual == attested
            else { return false }
        }
        return true
    }

    /// The decision core. `observed` covers the files actually on disk; files
    /// present but not pinned are ignored (upstream is free to add a README).
    ///
    /// Ordering rule: tampering outranks incompleteness. A half-downloaded
    /// directory that ALSO contains one wrong file is an attack in progress,
    /// not a slow download, and must not be reported as the benign case.
    /// `unreadable` names pinned files that ARE on disk but could not be read
    /// or hashed. Keeping that distinct from absence is load-bearing: the
    /// first cut folded both into "not in `observed`", so an unreadable file
    /// took the benign in-flight path and the load proceeded having never
    /// confirmed its bytes. The code could tell confirmed-missing from
    /// confirmed-wrong, but had no way to say "couldn't check".
    public static func verdict(
        pin: Pin?,
        observed: [String: ObservedFile],
        unreadable: Set<String> = []
    ) -> Verdict {
        guard let pin else { return .unpinned }

        var missing: [String] = []
        var tampered: [String] = []
        var unverifiable: [String] = []

        for (name, expected) in pin.files {
            if unreadable.contains(name) {
                unverifiable.append(name)
                continue
            }
            guard let actual = observed[name] else {
                missing.append(name)
                continue
            }
            if actual.size != expected.size || actual.sha256 != expected.sha256 {
                tampered.append(name)
            }
        }

        // Severity order: a known-wrong file is the worst news, then one we
        // could not check, then one that simply has not arrived yet.
        if !tampered.isEmpty { return .tampered(files: tampered.sorted()) }
        if !unverifiable.isEmpty { return .unverifiable(files: unverifiable.sorted()) }
        if !missing.isEmpty { return .incomplete(missing: missing.sorted()) }
        return .verified
    }
}

/// Thrown when downloaded weights disagree with the pinned manifest. Not a
/// network error by construction, so `withRetry` will not spin on it.
public struct WeightTamperError: LocalizedError, CustomStringConvertible, Sendable {
    public let repoID: String
    public let files: [String]

    public init(repoID: String, files: [String]) {
        self.repoID = repoID
        self.files = files
    }

    public var description: String {
        """
        Refusing to load \(repoID): downloaded weights do not match the digests \
        pinned in this build (\(files.joined(separator: ", "))). The files were \
        NOT deleted — they are evidence. This is not retried on purpose.
        """
    }

    /// `LocalizedError`: the same text, so `localizedDescription` is not
    /// "The operation couldn't be completed."
    public var errorDescription: String? {
        description
    }
}

/// Thrown when the cache holds a DIFFERENT pinned revision's weights — last
/// release's model, not an attack.
///
/// This exists so a promotion cannot slander its own users. After a re-pin, a
/// cache still holding the previous release's bytes legitimately disagrees
/// with the new manifest. Online that never surfaces, because the new revision
/// downloads first — but `download`'s offline and auth-required exits hand
/// back the stale local copy and verify THAT, so an honest user launching
/// without a network was met with a supply-chain accusation, permanently,
/// on a path built never to self-heal.
///
/// Distinguishing the two is possible because HubApi records the commit each
/// file was fetched at, so "wrong bytes for this commit" and "right bytes for
/// a different commit" are separable facts.
public struct WeightsStaleError: LocalizedError, CustomStringConvertible, Sendable {
    public let repoID: String
    public let localRevision: String
    public let pinnedRevision: String

    public init(repoID: String, localRevision: String, pinnedRevision: String) {
        self.repoID = repoID
        self.localRevision = localRevision
        self.pinnedRevision = pinnedRevision
    }

    public var description: String {
        """
        The cached weights for \(repoID) are from an earlier release \
        (\(localRevision.prefix(12))), but this build expects \
        \(pinnedRevision.prefix(12)). Nothing is wrong with them — they are \
        simply out of date. Reconnect and they will update.
        """
    }

    public var errorDescription: String? {
        description
    }
}

/// Thrown when a pinned file is present but could not be read or hashed, so
/// its bytes were never confirmed.
///
/// Distinct from `WeightTamperError` on purpose. This is not an accusation —
/// a permissions problem or a disk hiccup is far likelier than an attack — but
/// it still fails closed, because "we could not check" must never take the
/// same silent path as "it has not downloaded yet". Naming it separately keeps
/// the tamper `.fault` meaningful: if that one ever fires, it means something.
public struct WeightUnverifiableError: LocalizedError, CustomStringConvertible, Sendable {
    public let repoID: String
    public let files: [String]

    public init(repoID: String, files: [String]) {
        self.repoID = repoID
        self.files = files
    }

    public var description: String {
        """
        Could not verify \(repoID): \(files.joined(separator: ", ")) could not be \
        read to check against the pinned digests. Not loading unverified weights. \
        Most likely a file-permission or disk problem — retry, and if it persists \
        the model cache may need clearing.
        """
    }

    public var errorDescription: String? {
        description
    }
}
