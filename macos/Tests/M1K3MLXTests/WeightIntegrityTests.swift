//
//  WeightIntegrityTests.swift
//  M1K3MLXTests
//
//  The pure verdict rules for weight pinning. Every case here is a decision
//  about trust, so each one is pinned explicitly — especially the distinction
//  the whole design turns on: an ABSENT file is a download in progress, a
//  PRESENT file with the wrong bytes is an attack.
//

import Foundation
import M1K3Inference
@testable import M1K3MLX
import Testing

struct WeightIntegrityTests {
    /// A two-file pin standing in for a real repo: one big shard, one small
    /// config. Digests are arbitrary but fixed — the rules under test are
    /// about agreement, not about any particular hash.
    private static let pin = WeightIntegrity.Pin(
        revision: "aaaabbbbccccdddd",
        files: [
            "model.safetensors": .init(size: 2_263_022_417, sha256: "2a73c6c2"),
            "config.json": .init(size: 938, sha256: "574349e5"),
        ]
    )

    private func observed(
        _ pairs: [String: (Int, String)]
    ) -> [String: WeightIntegrity.ObservedFile] {
        pairs.mapValues { WeightIntegrity.ObservedFile(size: $0.0, sha256: $0.1) }
    }

    @Test("no pin for a repo is not a failure — spikes and legacy caches still load")
    func unpinnedRepoPasses() {
        let verdict = WeightIntegrity.verdict(
            pin: nil,
            observed: observed(["whatever.safetensors": (1, "ff")])
        )
        #expect(verdict == .unpinned)
    }

    @Test("every pinned file present with matching size and digest verifies")
    func allMatchingVerifies() {
        let verdict = WeightIntegrity.verdict(
            pin: Self.pin,
            observed: observed([
                "model.safetensors": (2_263_022_417, "2a73c6c2"),
                "config.json": (938, "574349e5"),
            ])
        )
        #expect(verdict == .verified)
    }

    @Test("an absent pinned file is an in-flight download, NOT an alarm")
    func missingFileIsIncomplete() {
        let verdict = WeightIntegrity.verdict(
            pin: Self.pin,
            observed: observed(["config.json": (938, "574349e5")])
        )
        #expect(verdict == .incomplete(missing: ["model.safetensors"]))
    }

    @Test("a present file whose digest disagrees is tampering — refuse")
    func digestMismatchIsTampered() {
        let verdict = WeightIntegrity.verdict(
            pin: Self.pin,
            observed: observed([
                "model.safetensors": (2_263_022_417, "DEADBEEF"),
                "config.json": (938, "574349e5"),
            ])
        )
        #expect(verdict == .tampered(files: ["model.safetensors"]))
    }

    @Test("a size disagreement is conclusive on its own — no digest needed")
    func sizeMismatchIsTampered() {
        let verdict = WeightIntegrity.verdict(
            pin: Self.pin,
            observed: observed([
                "model.safetensors": (99, "2a73c6c2"),
                "config.json": (938, "574349e5"),
            ])
        )
        #expect(verdict == .tampered(files: ["model.safetensors"]))
    }

    @Test("tampering outranks incompleteness — a wrong file beside a missing one still alarms")
    func tamperOutranksMissing() {
        let verdict = WeightIntegrity.verdict(
            pin: Self.pin,
            observed: observed(["config.json": (938, "WRONG")])
        )
        #expect(verdict == .tampered(files: ["config.json"]))
    }

    @Test("every mismatching file is named, sorted, so the log identifies the whole blast radius")
    func reportsAllTamperedFilesSorted() {
        let verdict = WeightIntegrity.verdict(
            pin: Self.pin,
            observed: observed([
                "model.safetensors": (2_263_022_417, "WRONG"),
                "config.json": (938, "ALSO-WRONG"),
            ])
        )
        #expect(verdict == .tampered(files: ["config.json", "model.safetensors"]))
    }

    @Test("unpinned extras alongside pinned files are ignored — upstream may add README/.gitattributes")
    func extraFilesIgnored() {
        let verdict = WeightIntegrity.verdict(
            pin: Self.pin,
            observed: observed([
                "model.safetensors": (2_263_022_417, "2a73c6c2"),
                "config.json": (938, "574349e5"),
                "README.md": (84, "whatever"),
            ])
        )
        #expect(verdict == .verified)
    }

    @Test("an empty directory is incomplete in pinned-file order, not tampered")
    func emptyDirectoryIsIncomplete() {
        let verdict = WeightIntegrity.verdict(pin: Self.pin, observed: [:])
        #expect(verdict == .incomplete(missing: ["config.json", "model.safetensors"]))
    }
}

struct UnverifiableFileTests {
    private static let pin = WeightIntegrity.Pin(
        revision: "aaaabbbbccccdddd",
        files: [
            "model.safetensors": .init(size: 2_263_022_417, sha256: "2a73c6c2"),
            "config.json": .init(size: 938, sha256: "574349e5"),
        ]
    )

    /// Review catch. The first cut could only tell "confirmed missing" from
    /// "confirmed wrong" — a file that was PRESENT but unreadable (permissions,
    /// an I/O error mid-hash) simply never made it into `observed`, so it read
    /// as absent, which is the benign `.incomplete` path, and the load
    /// proceeded with that file's bytes never confirmed. "Couldn't check" is
    /// not "nothing to check": it has to fail closed.
    @Test("a present but unreadable file is unverifiable, never silently incomplete")
    func unreadableIsNotIncomplete() {
        let verdict = WeightIntegrity.verdict(
            pin: Self.pin,
            observed: ["config.json": .init(size: 938, sha256: "574349e5")],
            unreadable: ["model.safetensors"]
        )
        #expect(verdict == .unverifiable(files: ["model.safetensors"]))
    }

    @Test("tampering still outranks unverifiability — a known-wrong file is the worse news")
    func tamperOutranksUnverifiable() {
        let verdict = WeightIntegrity.verdict(
            pin: Self.pin,
            observed: ["config.json": .init(size: 938, sha256: "WRONG")],
            unreadable: ["model.safetensors"]
        )
        #expect(verdict == .tampered(files: ["config.json"]))
    }

    @Test("unverifiability outranks incompleteness — an unreadable file is not a slow download")
    func unverifiableOutranksIncomplete() {
        let verdict = WeightIntegrity.verdict(
            pin: Self.pin,
            observed: [:],
            unreadable: ["config.json"]
        )
        #expect(verdict == .unverifiable(files: ["config.json"]))
    }
}

struct RevisionResolutionTests {
    private static let pin = WeightIntegrity.Pin(
        revision: "73bcf09092aa277861d5a191b989b666f7f32e8f",
        files: ["model.safetensors": .init(size: 1, sha256: "aa")]
    )

    /// The bug this exists to prevent, found in security review of the first
    /// cut. `resolve` in mlx-swift-lm passes `configuration.id`'s revision
    /// EXPLICITLY, and `ModelConfiguration.Identifier.id` defaults it to the
    /// literal `"main"` — never nil. So a `requested ?? pin` precedence meant
    /// every real load resolved against a moving branch, and only the
    /// background pre-stager (the one caller passing nil) honoured the pin.
    /// Pinned means pinned: the manifest wins over any caller.
    @Test("a caller-supplied revision does NOT override the pin — including the SDK's default main")
    func pinBeatsCallerRevision() {
        #expect(WeightIntegrity.resolveRevision(requested: "main", pin: Self.pin) == Self.pin.revision)
        #expect(WeightIntegrity.resolveRevision(requested: "a-branch", pin: Self.pin) == Self.pin.revision)
        #expect(WeightIntegrity.resolveRevision(requested: nil, pin: Self.pin) == Self.pin.revision)
    }

    @Test("an unpinned repo still honours the caller, then falls back to main")
    func unpinnedHonoursCaller() {
        #expect(WeightIntegrity.resolveRevision(requested: "abc123", pin: nil) == "abc123")
        #expect(WeightIntegrity.resolveRevision(requested: nil, pin: nil) == "main")
    }
}

struct ReceiptValidityTests {
    private static let pin = WeightIntegrity.Pin(
        revision: "aaaabbbbccccdddd",
        files: [
            "model.safetensors": .init(size: 2_263_022_417, sha256: "2a73c6c2"),
            "config.json": .init(size: 938, sha256: "574349e5"),
        ]
    )

    private static let stamps: [String: WeightIntegrity.FileStamp] = [
        "model.safetensors": .init(size: 2_263_022_417, modified: 1000),
        "config.json": .init(size: 938, modified: 1000),
    ]

    private static var receipt: WeightIntegrity.Receipt {
        .init(revision: pin.revision, files: stamps)
    }

    @Test("an untouched directory verified under this revision is trusted without rehashing")
    func untouchedIsTrusted() {
        #expect(WeightIntegrity.receiptStillValid(receipt: Self.receipt, pin: Self.pin, observed: Self.stamps))
    }

    /// The second security-review finding. The first cut stored only the pin's
    /// own constants, so `receipt.revision == pin.revision` compared a source
    /// constant to itself and could never disagree, and the sizes were likewise
    /// the pin's. A file re-fetched from a compromised host at the SAME SIZE —
    /// plausible, since tensor shapes and quantisation all but fix a shard's
    /// size — was therefore trusted without ever being hashed again.
    /// Modification time is the cheap signal that a re-download really happened.
    @Test("a re-downloaded file forces a rehash even when its size is unchanged")
    func refetchAtSameSizeForcesRehash() {
        var touched = Self.stamps
        touched["model.safetensors"] = .init(size: 2_263_022_417, modified: 2000)
        #expect(!WeightIntegrity.receiptStillValid(receipt: Self.receipt, pin: Self.pin, observed: touched))
    }

    @Test("a receipt from a different revision cannot vouch for the current pin")
    func staleRevisionRejected() {
        let stale = WeightIntegrity.Receipt(revision: "old-revision", files: Self.stamps)
        #expect(!WeightIntegrity.receiptStillValid(receipt: stale, pin: Self.pin, observed: Self.stamps))
    }

    @Test("a file missing from disk invalidates the receipt")
    func missingFileRejected() {
        var partial = Self.stamps
        partial["config.json"] = nil
        #expect(!WeightIntegrity.receiptStillValid(receipt: Self.receipt, pin: Self.pin, observed: partial))
    }

    @Test("a receipt that never covered a pinned file cannot vouch for it")
    func receiptMissingPinnedFileRejected() {
        var thin = Self.stamps
        thin["model.safetensors"] = nil
        let receipt = WeightIntegrity.Receipt(revision: Self.pin.revision, files: thin)
        #expect(!WeightIntegrity.receiptStillValid(receipt: receipt, pin: Self.pin, observed: Self.stamps))
    }

    @Test("a size that disagrees with the pin invalidates the receipt")
    func sizeDisagreementRejected() {
        let shrunk: [String: WeightIntegrity.FileStamp] = [
            "model.safetensors": .init(size: 2_263_022_417, modified: 1000),
            "config.json": .init(size: 12, modified: 1000),
        ]
        let receipt = WeightIntegrity.Receipt(revision: Self.pin.revision, files: shrunk)
        #expect(!WeightIntegrity.receiptStillValid(receipt: receipt, pin: Self.pin, observed: shrunk))
    }
}

struct PinnedWeightsTests {
    @Test("both shipping brains are pinned — the tiers a user can actually select")
    func shippingBrainsArePinned() {
        #expect(PinnedWeights.pin(for: "mlx-community/gemma-4-12B-it-4bit") != nil)
        #expect(PinnedWeights.pin(for: "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510") != nil)
    }

    /// The embedder is quieter than the brains but is the same exposure:
    /// third-party weights fetched at runtime and handed to MLX. It routes
    /// through the same `HubApiDownloader.download` choke point, so pinning
    /// it costs nothing extra and leaving it out would be an arbitrary hole.
    @Test("the retrieval embedder is pinned too, not just the chat brains")
    func embedderIsPinned() {
        #expect(PinnedWeights.pin(for: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ") != nil)
    }

    /// The two download bases genuinely diverge — LLM weights live under
    /// Caches (`HubApiDownloader.llmDefault`), embedder weights under
    /// Documents/huggingface (`.embedderDefault`), a 2.x layout preserved
    /// byte-for-byte so existing caches keep working. An import that assumed
    /// one base for everything would install the embedder somewhere the
    /// loader never looks: a silent no-op that then re-downloads.
    @Test("each pinned repo declares which download base it belongs to")
    func everyPinnedRepoHasADownloadBase() {
        #expect(PinnedWeights.downloadBase(for: "mlx-community/gemma-4-12B-it-4bit") == .llm)
        #expect(PinnedWeights.downloadBase(for: "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510") == .llm)
        #expect(
            PinnedWeights.downloadBase(for: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ") == .embedder
        )
    }

    @Test("every pinned repo has a base, so none can silently default to the wrong directory")
    func noPinnedRepoLacksABase() {
        for repo in PinnedWeights.all.keys {
            #expect(PinnedWeights.downloadBase(for: repo) != nil, "\(repo) declares no download base")
        }
    }

    @Test("an unknown repo has no pin — spikes and A/B overrides stay loadable")
    func unknownRepoUnpinned() {
        #expect(PinnedWeights.pin(for: "mlx-community/some-experimental-quant") == nil)
    }

    @Test("every pinned revision is a full 40-char git SHA, never a branch name")
    func revisionsAreCommitSHAs() {
        for (repo, pin) in PinnedWeights.all {
            #expect(pin.revision.count == 40, "\(repo) revision is not a full SHA")
            #expect(
                pin.revision.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                "\(repo) revision is not lowercase hex"
            )
        }
    }

    @Test("every pinned digest is a full sha256 and every size is positive")
    func digestsAreWellFormed() {
        for (repo, pin) in PinnedWeights.all {
            for (name, file) in pin.files {
                #expect(file.sha256.count == 64, "\(repo)/\(name) digest is not sha256-length")
                #expect(
                    file.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                    "\(repo)/\(name) digest is not lowercase hex"
                )
                #expect(file.size > 0, "\(repo)/\(name) has a non-positive size")
            }
        }
    }

    /// The guard that makes pinning survive contact with a model promotion.
    ///
    /// An unpinned repo loads normally by design, so a tier swapped without
    /// re-running `tools/weights/pin_weights.py` would silently ship
    /// unverified weights — a security regression that breaks nothing visible
    /// and would sail through review. Deriving the expectation from
    /// `BrainTier` itself, rather than a hand-listed set, means the swap
    /// itself turns this red. Both brains moved inside 26 hours in July 2026;
    /// assume the next promotion is in a hurry too.
    @Test("every selectable brain's weights are pinned — a promotion cannot silently unpin")
    func everySelectableBrainIsPinned() {
        for tier in BrainTier.allCases {
            guard let modelID = tier.mlxModelID else { continue }
            #expect(
                PinnedWeights.pin(for: modelID) != nil,
                """
                BrainTier.\(tier) ships \(modelID) with no pin. Add it to \
                SHIPPED_REPOS and re-run tools/weights/pin_weights.py.
                """
            )
        }
    }

    /// The published JSON manifest and the Swift manifest the app enforces are
    /// generated together by `pin_weights.py`, so they cannot disagree AT
    /// generation. But `--check` needs a local snapshot plus a live HF call, so
    /// it never runs in CI — leaving a hand-edit or a bad merge free to drift
    /// the two silently. `MIRRORING_WEIGHTS.md` tells third parties to trust the
    /// JSON, so a drift between it and what the app actually enforces is exactly
    /// the thing worth guarding directly. This loads the checked-in JSON and
    /// asserts it matches `PinnedWeights` field-for-field — pure, no network,
    /// no weights. (Review catch.)
    @Test("the published JSON manifest matches what the app enforces, field for field")
    func publishedManifestMatchesPinnedWeights() throws {
        struct FileEntry: Decodable { let size: Int; let sha256: String }
        struct RepoEntry: Decodable { let revision: String; let downloadBase: String; let files: [String: FileEntry] }
        struct Manifest: Decodable { let repos: [String: RepoEntry] }

        // macos/Tests/M1K3MLXTests/<thisfile> → up three → macos/, then the JSON.
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("weights-manifest.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))

        #expect(Set(manifest.repos.keys) == Set(PinnedWeights.all.keys))

        for (repo, pin) in PinnedWeights.all {
            let published = try #require(manifest.repos[repo], "\(repo) missing from JSON manifest")
            #expect(published.revision == pin.revision, "\(repo) revision drift")
            #expect(
                WeightIntegrity.DownloadBase(rawValue: published.downloadBase) == PinnedWeights.downloadBase(for: repo),
                "\(repo) downloadBase drift"
            )
            #expect(Set(published.files.keys) == Set(pin.files.keys), "\(repo) file-set drift")
            for (name, pinnedFile) in pin.files {
                let publishedFile = try #require(published.files[name], "\(repo)/\(name) missing from JSON")
                #expect(publishedFile.size == pinnedFile.size, "\(repo)/\(name) size drift")
                #expect(publishedFile.sha256 == pinnedFile.sha256, "\(repo)/\(name) sha256 drift")
            }
        }
    }

    @Test("the weight-bearing files are pinned, not just the small configs")
    func weightsThemselvesArePinned() {
        for (repo, pin) in PinnedWeights.all {
            let hasWeights = pin.files.keys.contains { $0.hasSuffix(".safetensors") }
            #expect(hasWeights, "\(repo) pins no .safetensors — the weights are unprotected")
        }
    }
}
