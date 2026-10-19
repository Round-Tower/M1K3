//
//  ChatEvalStageWiringTests.swift
//  M1K3EvalTests
//
//  The eval stage lives in the app target, so its launch wiring is pinned by reading the source (the
//  AskSurfaceCallSiteTests idiom). Two facts the app has and the eval lacked (#643 follow-ups):
//   1. One embedder per launch. The stage built an MLXEmbeddingService per fixture, which reloaded the 1.2 GB
//      checkpoint and asked Hugging Face for its file list inside every fixture's timed window (~8.3 s a turn).
//   2. The brain is prepared before fixture 1, as the app's readiness gate does, so fixture 1 isn't charged
//      the load.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-19, Confidence 0.8 (a text scan: a rename of the functions or the calls
//  must update the anchors here, and each anchor is asserted to exist first). Prior: none (new file).
//  Review: same day (pre-push review fold) — the scans skip `//` lines, anchor the embedder's declaration and want
//  `Self.embedder` in both per-fixture bodies.
//

import Foundation
import Testing

struct ChatEvalStageWiringTests {
    private static func stageSource() throws -> String {
        var root = URL(filePath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root = root.deletingLastPathComponent()
            try #require(root.path != "/", "no Package.swift above \(#filePath)")
        }
        return try String(contentsOf: root.appending(path: "M1K3App/ChatEvalStage.swift"), encoding: .utf8)
    }

    /// The body of the static func whose declaration starts with `head`, to the next member declaration.
    private static func body(of head: String, in text: String) throws -> Substring {
        let start = try #require(text.range(of: head), "anchor missing: \(head)")
        let rest = text[start.upperBound...]
        let next = ["\n    private static func ", "\n    static func ", "\n    private static var ", "\n    static var ",
                    "\n    private static let ", "\n    static let "]
            .compactMap { rest.range(of: $0)?.lowerBound }
            .min() ?? rest.endIndex
        return rest[..<next]
    }

    /// The stage's code without its `//` comment lines, so a doc mentioning a call can't satisfy or break a scan.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("the eval holds one embedder per launch, never one per fixture")
    func oneEmbedderPerLaunch() throws {
        let text = try Self.code(Self.stageSource())
        #expect(text.contains("private static let embedder = MLXEmbeddingService()"))
        #expect(text.components(separatedBy: "MLXEmbeddingService(").count - 1 == 1)
        for head in ["private static func livePathObservation(", "private static func groundedObservation("] {
            let body = try Self.body(of: head, in: text)
            #expect(!body.contains("MLXEmbeddingService("), "\(head) builds its own")
            #expect(body.contains("Self.embedder"), "\(head) doesn't use the launch's embedder")
        }
    }

    @Test("an MLX brain is prepared before fixture 1, as the app's readiness gate does")
    func brainPreparedBeforeFixtureOne() throws {
        let body = try Self.body(of: "private static func evalBrain(", in: Self.code(Self.stageSource()))
        let prepare = try #require(body.range(of: ".prepare("), "no prepare in evalBrain")
        let fixtures = try #require(body.range(of: "evalProvider("), "anchor missing: evalProvider(")
        #expect(prepare.lowerBound < fixtures.lowerBound)
    }
}
