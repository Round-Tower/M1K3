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
//  Review: Kev + claude-opus-5.5, 2026-10-26 — #716 review fold: `spokenTextFeedsBothArmsLikeAutoSpeak`. The spoken
//  check skips on a nil spoken text, so a dropped `spokenText:` argument would turn the voice fixtures green by skip:
//  both arms are pinned, `spokenText(of:)` to auto-speak's seams (and never the whole-answer polish), format to the
//  live arm, and the stop matcher to the one `AppEnvironment+AutoSpeak` uses. Red against a mutated stage (bare arm
//  without the argument, a whole-answer polish), restored byte for byte. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-26 — the `mechanic` arm (#697) wires like the app: the scenario runs
//  through `CoolHeadPolicy.advance` into a `CoolHeadNoteSlot` the responder takes from, and `.note` is captured.
//  Review: Kev + claude-opus-5.5, 2026-10-26 — #697 pre-push review fold: `runEmbeds` keeps its `mechanic` clause,
//  so a mechanic-only run warms the embedder before fixture 1. Confidence 0.85.
//

import Foundation
import Testing

struct ChatEvalStageWiringTests {
    private static func stageSource() throws -> String {
        try appSource("M1K3App/ChatEvalStage.swift")
    }

    /// A file under `macos/`, found by walking up to `Package.swift`.
    private static func appSource(_ path: String) throws -> String {
        var root = URL(filePath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root = root.deletingLastPathComponent()
            try #require(root.path != "/", "no Package.swift above \(#filePath)")
        }
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
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

    /// #716: `spoken has no markup` SKIPS when the observation carries no spoken text, and a skip never fails a
    /// fixture, so a dropped `spokenText:` argument (or a return to the whole-answer polish, which hid a real fail)
    /// would turn both voice fixtures quietly green. Pinned here: both arms hand it in, it is built from the same
    /// seams auto-speak speaks through, and the format kind takes the live arm when the live path is asked for.
    @Test("both arms hand in the spoken text, built the way auto-speak speaks, and format rides the live arm")
    func spokenTextFeedsBothArmsLikeAutoSpeak() throws {
        let text = try Self.code(Self.stageSource())
        #expect(text.components(separatedBy: "spokenText: spokenText(of: raw)").count - 1 == 2)
        let live = try Self.body(of: "private static func livePathObservation(", in: text)
        #expect(live.contains("spokenText: spokenText(of: raw)"), "the live arm drops the spoken text")
        #expect(text.contains("EvalObservation(rawText: raw, latencyMS: ms, spokenText: spokenText(of: raw))"),
                "the bare arm drops the spoken text")
        let spoken = try Self.body(of: "private static func spokenText(of ", in: text)
        let seams = ["ThinkStripper.strip(", "StreamedAnswerFolder(", "SpokenAnswerEnd.start(in:",
                     "FollowUpSplit.trailerStart", "SpeechTextPolish.spokenSentence"]
        for seam in seams {
            #expect(spoken.contains(seam), "spokenText(of:) lost \(seam)")
        }
        #expect(!spoken.contains("SpeechTextPolish.polish("), "a whole-answer polish hides a row cut by the fold")
        #expect(text.contains(".format where livePathRequested"))
        // Parity with what auto-speak speaks: the same stop matcher in both files.
        let stop = "SpokenAnswerEnd.start(in: $0, followUps: FollowUpSplit.trailerStart(in:))"
        #expect(text.contains(stop))
        #expect(try Self.code(Self.appSource("M1K3App/AppEnvironment+AutoSpeak.swift")).contains(stop))
    }

    @Test("the mechanic arm takes the live path and folds its scenario through the app's own Cool Head step")
    func mechanicWiresLikeTheApp() throws {
        let text = try Self.code(Self.stageSource())
        let live = try Self.body(of: "private static func livePathObservation(", in: text)
        #expect(live.contains("CoolHeadPolicy.advance("), "the scenario must run the app's fold, not a copy of it")
        #expect(live.contains("CoolHeadNoteSlot()"), "the note must come out of the app's slot")
        #expect(live.contains("minRecoveryTurns: AppEnvironment.coolHeadMinRecoveryTurns"))
        #expect(live.contains("deviceNoun: HostPlatform.noun"))
        #expect(live.contains("turnNoteProvider: turnNote"))
        #expect(live.contains("case let .note(line)"), "the turn's notes must be captured")
        #expect(live.contains("turnNotes:"), "the captured notes must reach the observation")
        #expect(
            !live.contains("ProcessInfo.processInfo.thermalState"), "the eval Mac's own heat must never reach a fixture"
        )
        let run = try Self.body(of: "private static func runFixture(", in: text)
        let arm = try #require(run.range(of: "case .mechanic:"), "no mechanic arm in runFixture")
        let next = try #require(run[arm.upperBound...].range(of: "case "))
        #expect(run[arm.upperBound ..< next.lowerBound].contains("livePathObservation("))
    }

    @Test("a mechanic-only run still warms the embedder outside every fixture's clock")
    func mechanicRunWarmsTheEmbedder() throws {
        // `--kinds mechanic` sets no LIVE_PATH, so without its own clause the first mechanic fixture would pay
        // the embedder load and the Hugging Face file-list fetch inside its timed window (#643 follow-up 1).
        let embeds = try Self.body(of: "private static func runEmbeds(", in: Self.code(Self.stageSource()))
        #expect(embeds.contains("kinds.contains(.mechanic)"), "a mechanic-only run must still warm the embedder")
    }
}
