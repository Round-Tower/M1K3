//
//  RepoSizeEstimateTests.swift
//  M1K3MLXTests
//
//  The honest download bar: HubApi's Progress is file-weighted, so the UI sat
//  at "25%" for minutes while a 5GB safetensors streamed. RepoSizeEstimate
//  turns the HF tree listing into an expected byte total for the files the
//  loader will actually fetch, so progress can be synthesized from bytes.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-11-18 — matched on the repo path (fnmatch, as HubApi): an exact pinned name
//  counts the root file only, never a subfolder's duplicate.
//

import Foundation
@testable import M1K3MLX
import Testing

struct RepoSizeEstimateTests {
    private let entries = [
        RepoTreeEntry(type: "file", size: 1570, path: ".gitattributes"),
        RepoTreeEntry(type: "file", size: 666, path: "README.md"),
        RepoTreeEntry(type: "file", size: 7755, path: "chat_template.jinja"),
        RepoTreeEntry(type: "file", size: 3113, path: "config.json"),
        RepoTreeEntry(type: "file", size: 1_722_271_785, path: "model.safetensors"),
        RepoTreeEntry(type: "directory", size: 0, path: "assets"),
    ]

    @Test("sums only the files the loader's patterns will fetch")
    func sumsMatchedFiles() {
        let total = RepoSizeEstimate.expectedBytes(
            entries: entries,
            matching: ["*.safetensors", "*.json", "*.jinja"]
        )
        #expect(total == 1_722_271_785 + 3113 + 7755)
    }

    @Test("no matches means no estimate (nil, not zero)")
    func noMatchesIsNil() {
        let total = RepoSizeEstimate.expectedBytes(entries: entries, matching: ["*.bin"])
        #expect(total == nil)
    }

    @Test("nested paths match on the filename like HubApi does")
    func nestedPathsMatch() {
        let nested = [RepoTreeEntry(type: "file", size: 42, path: "subdir/weights.safetensors")]
        #expect(RepoSizeEstimate.expectedBytes(entries: nested, matching: ["*.safetensors"]) == 42)
    }

    /// A pinned repo's snapshot asks for exact names (snapshotPatterns, 2026-11-18). Matched on the bare filename,
    /// `model.safetensors` also counted `Q4/model.safetensors`, a duplicate pack the Hub no longer fetches, and the
    /// bar would stall near half (second review pass). Matched on the repo path, as HubApi's fnmatch does.
    @Test("an exact name counts the root file only, never a subfolder's copy; a glob still crosses '/'")
    func exactNamesMatchTheRepoPath() {
        let tree = [
            RepoTreeEntry(type: "file", size: 100, path: "model.safetensors"),
            RepoTreeEntry(type: "file", size: 100, path: "Q4/model.safetensors"),
            RepoTreeEntry(type: "file", size: 7, path: "1_Pooling/config.json"),
        ]
        #expect(RepoSizeEstimate.expectedBytes(entries: tree, matching: ["model.safetensors"]) == 100)
        #expect(RepoSizeEstimate.expectedBytes(entries: tree, matching: ["1_Pooling/config.json"]) == 7)
        #expect(RepoSizeEstimate.expectedBytes(entries: tree, matching: ["*.safetensors"]) == 200)
    }

    @Test("the tree JSON shape decodes")
    func decodesTreeJSON() throws {
        let json = #"[{"type":"file","oid":"abc","size":3113,"path":"config.json"}]"#
        let decoded = try JSONDecoder().decode([RepoTreeEntry].self, from: Data(json.utf8))
        #expect(decoded == [RepoTreeEntry(type: "file", size: 3113, path: "config.json")])
    }
}
