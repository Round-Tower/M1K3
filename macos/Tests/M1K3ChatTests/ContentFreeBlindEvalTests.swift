//
//  ContentFreeBlindEvalTests.swift
//  M1K3ChatTests
//
//  Opt-in (`M1K3_CONTENTFREE_BLIND=<set.json>[,<set.json>…]`): the content-free route over
//  written-blind follow-up sets. Each row is M1K3's previous message, the user's short reply and
//  the expected outcome ("chat", or "tool"/"search"). The real gate (Apple's sentence embedding)
//  scores the reply; master sends a tools verdict to the picker, the branch sends a content-free
//  reply to chat. Prints one line per row and a summary per set; deterministic, no model.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02, Confidence 0.8 (the route is pure; the sets were
//  written by models from a spec, never tuned on by the whitelist after round 1). Prior: Unknown.
//

import Foundation
@testable import M1K3Chat
import NaturalLanguage
import Testing

private let blindEnvironment = ProcessInfo.processInfo.environment

@Suite(.enabled(if: blindEnvironment["M1K3_CONTENTFREE_BLIND"] != nil))
struct ContentFreeBlindEvalTests {
    struct Row: Decodable {
        let id: String
        let assistant: String
        let user: String
        let expect: String
    }

    @Test("content-free replies route to chat; everything else keeps master's route")
    func score() throws {
        let embedder = NLSentenceEmbedder()
        let paths = (blindEnvironment["M1K3_CONTENTFREE_BLIND"] ?? "").split(separator: ",").map(String.init)
        for path in paths {
            let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            var free = (chat: 0, chatRight: 0, tool: 0)
            var other = (n: 0, same: 0)
            for row in rows {
                let gate = ToolNeedRouter.decide(for: row.user, embed: embedder.vector)
                let contentFree = ToolNeedRouter.isContentFree(row.user)
                let baseline = gate.verdict == .tools ? "picker" : "chat"
                let branch = gate.verdict == .tools && !contentFree ? "picker" : "chat"
                let wantsTool = row.expect != "chat"
                if contentFree {
                    if wantsTool { free.tool += 1 } else {
                        free.chat += 1
                        free.chatRight += branch == "chat" ? 1 : 0
                    }
                } else {
                    other.n += 1
                    other.same += baseline == branch ? 1 : 0
                }
                let p = gate.probability.map { String(format: "%.3f", $0) } ?? "none"
                print("[\(row.id)] expect=\(row.expect) p=\(p) free=\(contentFree) before=\(baseline) "
                    + "after=\(branch) :: \(row.user)")
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            print("SET \(name): \(rows.count) rows · content-free+expect chat → chat "
                + "\(free.chatRight)/\(free.chat) · content-free+expect tool \(free.tool) "
                + "(now chat, the accepted cost) · "
                + "replies with content on the old route \(other.same)/\(other.n)")
            #expect(free.chatRight == free.chat)
            #expect(other.same == other.n)
        }
    }
}
