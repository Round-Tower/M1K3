//
//  MemoryGraphEval.swift
//  M1K3Memory
//
//  An INTEGRATION eval for the temporal memory graph — distinct from M1K3Eval's
//  model-quality evals. It drives a real MemoryStore through a scripted scenario
//  (write facts → supersede → link → probe recall/traversal) and scores the
//  outcome. Two embedders, two jobs:
//
//    • off-device (HashingEmbeddingService): proves the STORE is structurally
//      correct — recall returns the right rows, supersession hides the old,
//      traversal reaches the linked. Keyword-overlap probes, so the keyword-only
//      fake satisfies them. This is what the unit tests assert.
//
//    • on-device (the real MLX embedder, via the headless self-test): proves
//      RECALL ACTUALLY WORKS on meaning. The `semantic` probes are paraphrases
//      that share little surface vocabulary with the stored fact — the hashing
//      fake CANNOT satisfy them (orthogonal vectors), a real embedder must.
//      That gap is the whole point: it's the difference between "the SQL is
//      right" and "the memory is useful".
//
//  Pure data + a pure-ish runner (the only effect is an in-memory MemoryStore).
//  No Bundle, no disk. Mirrors the ChatEvalFixtures/ScenarioReport shape.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.85 (harness + fixtures
//  TDD'd off-device against the hashing embedder; the semantic probes are
//  authored to FAIL on keyword overlap by design, so they only mean something on
//  the real-embedder self-test — that on-device run is the named verify-owed).
//  Prior: M1K3Eval ChatEvalFixtures (Kev + claude-opus-4-8).
//  Review: Kev + claude-fable-5.1, 2026-10-10 (one embedder: EmbeddingGemma 2) — the eval store's floors follow the embedder under test (recall's bar was Qwen's 0.35 for every embedder).

import Foundation
import M1K3Knowledge // EmbeddingService

// MARK: - Scenario

/// A fact to seed, addressed by a stable `label` so probes can name expectations
/// without knowing the generated UUID.
public struct MemoryFact: Sendable, Equatable {
    public let label: String
    public let kind: MemoryKind
    public let text: String
    public init(label: String, kind: MemoryKind = .note, text: String) {
        self.label = label
        self.kind = kind
        self.text = text
    }
}

/// `new` corrects `old` (both are facts already in the scenario by label).
public struct MemoryCorrection: Sendable, Equatable {
    public let oldLabel: String
    public let newLabel: String
    public let text: String
    public init(oldLabel: String, newLabel: String, text: String) {
        self.oldLabel = oldLabel
        self.newLabel = newLabel
        self.text = text
    }
}

/// A typed edge between two scenario facts, by label.
public struct MemoryLinkSpec: Sendable, Equatable {
    public let fromLabel: String
    public let toLabel: String
    public let relation: String
    public init(fromLabel: String, toLabel: String, relation: String) {
        self.fromLabel = fromLabel
        self.toLabel = toLabel
        self.relation = relation
    }
}

/// One assertion against the populated store.
public struct MemoryProbe: Sendable, Equatable {
    public enum Check: Sendable, Equatable {
        /// `recall(query)` must surface every label in `expect` and none in `absent`.
        case recalls(query: String, expect: [String], absent: [String])
        /// `related(to: seed, maxHops:)` must reach every label in `expect`.
        case relates(seed: String, maxHops: Int, expect: [String])
    }

    public let id: String
    public let check: Check
    /// True → the probe depends on semantic generalisation; only a real embedder
    /// can satisfy it. The off-device (hashing) run skips these.
    public let semantic: Bool

    public init(id: String, check: Check, semantic: Bool = false) {
        self.id = id
        self.check = check
        self.semantic = semantic
    }
}

public struct MemoryGraphScenario: Sendable {
    public let facts: [MemoryFact]
    public let corrections: [MemoryCorrection]
    public let links: [MemoryLinkSpec]
    public let probes: [MemoryProbe]

    public init(
        facts: [MemoryFact],
        corrections: [MemoryCorrection] = [],
        links: [MemoryLinkSpec] = [],
        probes: [MemoryProbe]
    ) {
        self.facts = facts
        self.corrections = corrections
        self.links = links
        self.probes = probes
    }
}

// MARK: - Report

public struct MemoryProbeResult: Sendable, Equatable, Identifiable {
    public let id: String
    public let passed: Bool
    public let semantic: Bool
    /// Human-readable reason on failure (or a one-line summary on pass).
    public let detail: String
}

public struct MemoryGraphReport: Sendable, Equatable {
    public let results: [MemoryProbeResult]

    public var passed: Int {
        results.filter(\.passed).count
    }

    public var failed: Int {
        results.count - passed
    }

    public var allPassed: Bool {
        failed == 0
    }

    /// A compact, stderr-friendly table for the self-test stream.
    public func summary() -> String {
        let lines = results.map { r in
            "  \(r.passed ? "✓" : "✗") \(r.id)\(r.semantic ? " [semantic]" : "")  \(r.detail)"
        }
        return (["MEMGRAPH \(passed)/\(results.count) passed"] + lines).joined(separator: "\n")
    }
}

// MARK: - Runner

public enum MemoryGraphEval {
    /// Build a fresh in-memory store, run the scenario, score the probes.
    ///
    /// `includeSemantic: false` (the off-device default) skips probes that need a
    /// real embedder, so the keyword-only hashing fake produces an all-pass on
    /// the structural set. On-device, pass `true` to demand semantic recall.
    public static func run(
        _ scenario: MemoryGraphScenario,
        embedder: any EmbeddingService,
        includeSemantic: Bool
    ) async throws -> MemoryGraphReport {
        let store = try MemoryStore()
        store.floors = EmbedderFloors.forFingerprint(embedder.fingerprint)
        var idByLabel: [String: UUID] = [:]

        // Seed facts.
        for fact in scenario.facts {
            let memory = Memory(kind: fact.kind, text: fact.text, source: "memgraph-eval")
            try store.remember(memory, embedding: await embedder.embed(fact.text))
            idByLabel[fact.label] = memory.id
        }
        // Apply corrections (supersession-over-time).
        for correction in scenario.corrections {
            guard let oldID = idByLabel[correction.oldLabel] else {
                throw EvalError.unknownLabel(correction.oldLabel)
            }
            let memory = Memory(kind: .note, text: correction.text, source: "memgraph-eval")
            try store.remember(memory, embedding: await embedder.embed(correction.text), supersedes: oldID)
            idByLabel[correction.newLabel] = memory.id
        }
        // Wire edges.
        for link in scenario.links {
            guard let from = idByLabel[link.fromLabel] else { throw EvalError.unknownLabel(link.fromLabel) }
            guard let to = idByLabel[link.toLabel] else { throw EvalError.unknownLabel(link.toLabel) }
            try store.link(MemoryEdge(fromID: from, toID: to, relation: link.relation))
        }

        var results: [MemoryProbeResult] = []
        for probe in scenario.probes where includeSemantic || !probe.semantic {
            try results.append(await score(probe, store: store, idByLabel: idByLabel, embedder: embedder))
        }
        return MemoryGraphReport(results: results)
    }

    private static func score(
        _ probe: MemoryProbe,
        store: MemoryStore,
        idByLabel: [String: UUID],
        embedder: any EmbeddingService
    ) async throws -> MemoryProbeResult {
        func id(_ label: String) throws -> UUID {
            guard let v = idByLabel[label] else { throw EvalError.unknownLabel(label) }
            return v
        }
        switch probe.check {
        case let .recalls(query, expect, absent):
            let hits = try store.recall(query: query, queryVector: await embedder.embedQuery(query), limit: 10)
            let hitIDs = Set(hits.map(\.memory.id))
            let missing = try expect.filter { try !hitIDs.contains(id($0)) }
            let leaked = try absent.filter { try hitIDs.contains(id($0)) }
            let ok = missing.isEmpty && leaked.isEmpty
            let detail = ok
                ? "recalled \(expect.count), excluded \(absent.count)"
                : "missing=\(missing) leaked=\(leaked)"
            return MemoryProbeResult(id: probe.id, passed: ok, semantic: probe.semantic, detail: detail)

        case let .relates(seed, maxHops, expect):
            let related = try store.related(to: id(seed), maxHops: maxHops)
            let relatedIDs = Set(related.map(\.id))
            let missing = try expect.filter { try !relatedIDs.contains(id($0)) }
            let ok = missing.isEmpty
            return MemoryProbeResult(
                id: probe.id, passed: ok, semantic: probe.semantic,
                detail: ok ? "reached \(expect.count) within \(maxHops) hops" : "unreached=\(missing)"
            )
        }
    }

    public enum EvalError: Error, Sendable, Equatable {
        case unknownLabel(String)
    }
}

// MARK: - Fixtures

public enum MemoryGraphFixtures {
    /// A small life-graph: facts about a user, one corrected over time, two
    /// linked into a relationship cluster. Structural probes use keyword overlap
    /// (any embedder passes); semantic probes paraphrase (real embedder only).
    public static let lifeGraph = MemoryGraphScenario(
        facts: [
            .init(label: "sister", kind: .profile, text: "Kev's sister is Aoife"),
            .init(label: "city-old", kind: .profile, text: "Kev lives in Dublin"),
            .init(label: "pet", kind: .profile, text: "Kev has a dog named Biscuit"),
            .init(label: "work", kind: .profile, text: "Kev builds local AI software"),
            .init(label: "decision", kind: .decision,
                  text: "Chose RRF over learned fusion for hybrid search on 06-11"),
        ],
        corrections: [
            // Kev moves: Dublin → Cork. The old fact must drop out of recall.
            .init(oldLabel: "city-old", newLabel: "city-new", text: "Kev lives in Cork"),
        ],
        links: [
            // The sister and the pet both belong to the "about Kev's home life"
            // cluster — a hand-authored relation the graph can traverse.
            .init(fromLabel: "sister", toLabel: "pet", relation: "about-person"),
        ],
        probes: [
            // ── Structural (keyword overlap → any embedder) ──────────────────
            .init(id: "recall-sister",
                  check: .recalls(query: "Kev sister Aoife", expect: ["sister"], absent: [])),
            .init(id: "supersede-city",
                  check: .recalls(query: "where Kev lives Cork Dublin",
                                  expect: ["city-new"], absent: ["city-old"])),
            .init(id: "traverse-homelife",
                  check: .relates(seed: "sister", maxHops: 1, expect: ["pet"])),
            // ── Semantic (paraphrase → real embedder only) ───────────────────
            // "sibling" shares no tokens with "sister"; a keyword fake scores 0.
            .init(id: "recall-sibling-paraphrase",
                  check: .recalls(query: "Who is Kev's sibling?", expect: ["sister"], absent: []),
                  semantic: true),
            // "canine companion" ≠ "dog named Biscuit" on the surface.
            .init(id: "recall-pet-paraphrase",
                  check: .recalls(query: "Does Kev have a canine companion?", expect: ["pet"], absent: []),
                  semantic: true),
            // An unrelated query must NOT drag in a profile fact (discrimination).
            .init(id: "recall-discrimination",
                  check: .recalls(query: "What is the capital of France?",
                                  expect: [], absent: ["sister", "pet", "work"]),
                  semantic: true),
        ]
    )
}
