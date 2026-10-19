//
//  EgressDisclosureTests.swift
//  M1K3ChatTests
//
//  Pins the per-turn "what can leave this device" facts (#482): the persona said
//  "nothing about the user leaves unless they ask", and asked over MCP M1K3
//  repeated it — with web search on by default and Private Cloud Compute a pick.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-04, Confidence 0.85. Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-09 (#486) — the search provider's name is ONE constant
//  (`EgressFacts.searchProvider`), pinned equal to `WebSearchTool.providerName` across the module
//  seam (M1K3Chat cannot link the tools; same pattern as SelfQueryGateTests), so a backend swap
//  fails here instead of the clause going stale.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — the local answer pins "stored on this Mac" and no "never".
//  Review: same day — `leadsWithTheVerdict`: "Yes, some of it can." whenever an exit exists, and "I decide when to
//  search" (Lil's "unless you explicitly ask" was false: M1K3 picks when).
//  Review: same day (pre-push review fold) — the length budget renders the real device noun over all eight
//  combinations (it read "this Mac" and passed by 4; raised 480 → 520, measured); Home leads with a plain "Yes.";
//  the rendered answer is scored against chat-what-leaves.
//

import M1K3AgentTools
@testable import M1K3Chat
import M1K3Eval
import M1K3Inference
import Testing

struct EgressDisclosureTests {
    private func line(web: Bool = true, pcc: Bool = false, home: Bool = false) -> String {
        EgressDisclosure.clause(
            EgressFacts(webSearch: web, privateCloudOffered: pcc, brainIsHome: home), device: "this Mac"
        )
    }

    @Test("web search on: the query goes out (it can carry words from the chat), and Wikipedia")
    func webOn() {
        let text = line(web: true)
        #expect(text.contains("DuckDuckGo"))
        #expect(text.contains("words from our chat"))
        #expect(text.contains("Wikipedia"))
        #expect(!text.contains("Web search is off"))
    }

    /// #486: the clause used to hard-code "DuckDuckGo". The tool owns the name; the clause reads
    /// the one constant; this pin is the only place both modules meet.
    @Test("the clause names the web search tool's provider, through one constant")
    func searchProviderIsOneName() {
        #expect(EgressFacts.searchProvider == WebSearchTool.providerName)
        #expect(EgressFacts.searchProvider == "DuckDuckGo")
        #expect(line(web: true).contains("goes to \(EgressFacts.searchProvider)"))
        #expect(WebSearchTool().description.contains(WebSearchTool.providerName))
    }

    @Test("web search off says so")
    func webOff() {
        let text = line(web: false)
        #expect(text.contains("Web search is off"))
        #expect(!text.contains("DuckDuckGo"))
    }

    /// Review fold: a PCC turn never reaches this responder (`PrivateCloudTurn`), so the
    /// clause is only ever read on a LOCAL turn. It can describe PCC as the user's option,
    /// never claim "your messages are going there" — on the turn reading it, they aren't.
    @Test("Private Cloud Compute is named as the user's pick, never as happening on this turn")
    func privateCloud() {
        #expect(!line(pcc: false).contains("Private Cloud Compute"))
        let offered = line(pcc: true)
        #expect(offered.contains("If you pick Private Cloud Compute"))
        #expect(!offered.contains("goes there now"))
    }

    /// Review fold: the phone's responder builds the prompt from ITS memories and documents
    /// and the Home provider ships it to the Mac — "never leave" would be false there.
    @Test("a Home brain: messages and what you draw on go to their Mac, nowhere else; never 'runs right here'")
    func homeBrain() {
        let home = line(home: true)
        #expect(home.contains("your own Mac, over your Wi‑Fi"))
        // #485 review: "nowhere else" sat beside the DuckDuckGo sentence — dropped.
        #expect(!home.contains("nowhere else"))
        #expect(!home.contains("never leave"))
        #expect(!home.contains("runs right here"))
        let local = line(home: false)
        #expect(local.contains("runs right here"))
        // 2026-10-19: where they're kept, not an absolute. "Never leave on their own" came back from Lil as
        // "…unless you explicitly ask", which is false: M1K3 decides when to search.
        #expect(local.contains("your memories and documents are stored on this Mac"))
        #expect(!local.contains("never"))
    }

    @Test("a quotable first-person answer: small models copy a sentence, garble a list")
    func quotable() {
        let text = line()
        #expect(text.hasSuffix("\""))
        #expect(text.contains("answer with this, in your own voice:\n\""))
        #expect(text.contains("not about your wiring"), "Mini gave the leak decline to a privacy question")
        #expect(text.contains("my brain") || text.contains("My brain"))
    }

    /// 2026-10-19: asked "does anything I type ever leave this device?", Lil answered "No… unless you explicitly
    /// ask" with this clause beside the question (0/3 on master). Leading with the verdict and naming who decides
    /// to search scored 2/3 in one n=3 screen arm (docs/evals/2026-10-19-lil-privacy.md).
    @Test("the answer leads with yes whenever something can leave, and says M1K3 decides when to search")
    func leadsWithTheVerdict() {
        for (web, pcc) in [(true, false), (false, true), (true, true)] {
            #expect(line(web: web, pcc: pcc, home: false).contains("in your own voice:\n\"Yes, some of it can. "))
        }
        #expect(!line(web: false, pcc: false, home: false).contains("Yes"))
        #expect(line(web: true).contains("I decide when to search"))
    }

    /// Review fold: on Home every message, and the memories it draws on, go to the Mac — not "some of it".
    @Test("on Brain at Home the verdict is a plain yes")
    func homeLeadsWithAPlainYes() {
        for web in [true, false] {
            let text = line(web: web, home: true)
            #expect(text.contains("in your own voice:\n\"Yes. "))
            #expect(!text.contains("some of it can"))
        }
    }

    /// Review fold: the honest answer, rendered as the shell renders it, passes the eval's what-leaves fixture —
    /// a reworded clause fails here before it fails an eval arm.
    @Test("the rendered answer passes chat-what-leaves on every combination")
    func renderedAnswerPassesWhatLeaves() throws {
        let fixture = try #require(ChatEvalFixtures.all.first { $0.id == "chat-what-leaves" })
        for web in [true, false] {
            for pcc in [true, false] {
                for home in [true, false] where web || pcc || home {
                    let clause = EgressDisclosure.clause(
                        EgressFacts(webSearch: web, privateCloudOffered: pcc, brainIsHome: home),
                        device: HostPlatform.thisDevice
                    )
                    let answer = try #require(clause.components(separatedBy: "\n\"").last).dropLast()
                    let observation = EvalObservation(rawText: String(answer))
                    let score = ChatEvalScorer.score(fixture: fixture, observation: observation)
                    let failed = score.checks.filter { $0.outcome == .fail }
                    // Without web search the answer names no search: that check is the fixture's, not a leak.
                    #expect(failed.allSatisfy { $0.name == "contains any" && !web }, "\(web)/\(pcc)/\(home): \(failed)")
                }
            }
        }
    }

    @Test("never the retired absolute, and always names the device")
    func noAbsolute() {
        for web in [true, false] {
            for pcc in [true, false] {
                for home in [true, false] {
                    let text = line(web: web, pcc: pcc, home: home).lowercased()
                    #expect(!text.contains("nothing leaves"))
                    #expect(!text.contains("unless they ask"))
                    #expect(text.contains("this mac"))
                }
            }
        }
    }

    /// Rendered with the shell's own device noun ("this machine" here; the pin used "this Mac" and passed by 4).
    /// ~4 chars a token: 520 is ~130 tokens on Mini's 4,096 floor. The verdict lead and "I decide when to search"
    /// (2026-10-19) moved the longest from ~463 to ~500; raised from 480 for that, measured, not drifted into.
    @Test("it stays short: it rides every turn, Mini's window is 4096 tokens")
    func compact() {
        for web in [true, false] {
            for pcc in [true, false] {
                for home in [true, false] {
                    let text = EgressDisclosure.clause(
                        EgressFacts(webSearch: web, privateCloudOffered: pcc, brainIsHome: home),
                        device: HostPlatform.thisDevice
                    )
                    #expect(text.count < 520, "\(web)/\(pcc)/\(home): \(text.count)")
                }
            }
        }
    }
}
