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
//  Review: Kev + claude-opus-5.5, 2026-11-04 — #775: `clauseStartsWithTheInstruction` pins the render byte-identical
//  after the instruction became a constant.
//  Review: Kev + claude-fable-5.1, 2026-11-05 — `applies(to:)`: the clause is for privacy asks only. Positives are
//  the phrasings the fixtures, the ramble probes and Kev's own asks use; negatives are what a fresh chat on the
//  phone actually gets (recipes, units, jokes). `appliesScoredOnTheFixtures` runs the cue list over EVERY chateval
//  fixture and ramble probe: the real privacy asks must hit, named ordinary asks must not, and the hit rate stays
//  under a ceiling (8 of 127 at the first run, cues trimmed after it). `homeClauseRidesEveryTurn` pins the Home
//  marker (pre-push security pass).
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

    /// 2026-10-19 gate: pocket (LFM2.5-1.2B) copied the verdict into unrelated answers ("Yes, some of it can— A cat
    /// naps…", 3 of 3 couplets). Its clause starts at the facts; every other variant keeps the lead.
    @Test("pocket's clause keeps every fact but drops the quotable verdict lead")
    func pocketDropsTheLead() {
        for home in [true, false] {
            let full = line(web: true, pcc: !home, home: home)
            let pocket = EgressDisclosure.adapted(full, for: .pocket)
            #expect(!pocket.contains("own voice:\n\"Yes"))
            #expect(pocket.contains("own voice:\n\"Web searches: I decide when to search"))
            #expect(pocket.hasSuffix("\""))
            #expect(EgressDisclosure.adapted(full, for: .standard) == full)
        }
        let quiet = line(web: false, pcc: false, home: false)
        #expect(EgressDisclosure.adapted(quiet, for: .pocket) == quiet)
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

    /// #775: the instruction became a constant the leak guard fingerprints; the render must not move a byte.
    @Test("the clause still opens with today's exact words: the instruction constant moved no byte")
    func clauseStartsWithTheInstruction() {
        #expect(EgressDisclosure.instruction
            == "a fair privacy question, not about your wiring — answer with this, in your own voice:")
        for device in ["this machine", "this device"] {
            let text = EgressDisclosure.clause(EgressFacts(webSearch: true, privateCloudOffered: true), device: device)
            #expect(text.hasPrefix("If asked what leaves \(device) — a fair privacy question, not about your wiring — "
                    + "answer with this, in your own voice:\n\"Yes, some of it can. "))
        }
    }

    // MARK: - applies(to:) — the clause rides privacy asks only (2026-11-05)

    @Test("a privacy ask, however phrased, gets the clause")
    func appliesToPrivacyAsks() {
        let asks = [
            "Is my data private?",
            "Be honest: does anything I type into you ever leave this device?",
            "Are my chats private?",
            "where are my memories stored?",
            "Why should I trust you with my private documents?",
            "do you upload my documents anywhere?",
            "is everything offline?",
            "does it go to the cloud?",
            "Are you listening to me right now?",
            "who else can see what I type — is this encrypted?",
            "does anything I type get sent anywhere?",
            "are you recording me?",
            "is this logged or saved somewhere?",
            "do you sell my personal info?",
            "will you leak my secrets to hackers?",
            "¿Mis datos son privados?",
            "Sind meine Daten privat?",
            "mes données restent-elles privées ?",
            "Мои данные приватны?",
        ]
        for ask in asks {
            #expect(EgressDisclosure.applies(to: ask), "\(ask)")
        }
    }

    @Test("an ordinary fresh-chat ask gets no clause")
    func appliesNotToOrdinaryAsks() {
        let asks = [
            "give me a recipe for banana bread",
            "send me a quick tomato pasta recipe",
            "how many grams in a pound?",
            "What's the capital of Australia?",
            "tell me a joke",
            "yo",
            "what do you think of pineapple on pizza?",
            "make me a simple web page that says hello",
            "latest Apple news?",
            "is it safe to eat raw eggs?",
            "who's the pirate in your story?",
        ]
        for ask in asks {
            #expect(!EgressDisclosure.applies(to: ask), "\(ask)")
        }
    }

    @Test("whole words after folding: 'PRIVATE,' and 'privately' hit; 'pirate' and 'leaven' do not")
    func appliesMatchesWholeFoldedWords() {
        #expect(EgressDisclosure.applies(to: "Is this PRIVATE, really?"))
        #expect(EgressDisclosure.applies(to: "is it kept privately"))
        #expect(EgressDisclosure.applies(to: "Dáta — is it sáfe?"), "diacritics fold before the cue check")
        #expect(!EgressDisclosure.applies(to: "the pirate and the leaven"))
    }

    /// Every chateval fixture and every ramble probe. A hit is a turn that carries the clause: the two real
    /// privacy asks must; the named ordinary asks (a maths word problem, the marathon record, a plant leak, a
    /// capital) must not; and the rest stays under a ceiling, because every false positive is a turn that keeps
    /// the old opener. First run (2026-11-05): 8 of 127 fixtures (chat-what-leaves, interview-why-trust, and six
    /// that say "share", "uploaded", "stored", "data" or "secure"), 1 of 13 probes. Not an exact pin: a fixture
    /// edit that says "data" must not fail an unrelated PR.
    @Test("the cue list scored on the fixtures and the ramble probes: privacy asks hit, ordinary asks miss")
    func appliesScoredOnTheFixtures() {
        let fixtureHits = ChatEvalFixtures.all.filter { EgressDisclosure.applies(to: $0.prompt) }.map(\.id)
        let probeHits = MiniRambleEvalTests.probes.filter { EgressDisclosure.applies(to: $0.question) }.map(\.id)
        for id in ["chat-what-leaves", "interview-why-trust"] {
            #expect(fixtureHits.contains(id), "\(id) must carry the clause")
        }
        for id in ["tool-web-unguarded-record", "reason-apples", "long-incident-names", "tool-head-capital"] {
            #expect(!fixtureHits.contains(id), "\(id) must not carry the clause")
        }
        #expect(fixtureHits.count * 10 <= ChatEvalFixtures.all.count, "\(fixtureHits.joined(separator: ", "))")
        #expect(probeHits.contains("private"))
        #expect(!probeHits.contains("make") && !probeHits.contains("capital") && !probeHits.contains("yo"))
    }

    @Test("a Home clause rides every turn; the local and PCC clauses only a privacy ask's")
    func homeClauseRidesEveryTurn() {
        #expect(EgressDisclosure.ridesEveryTurn(line(home: true)))
        #expect(EgressDisclosure.ridesEveryTurn(line(web: false, home: true)))
        #expect(!EgressDisclosure.ridesEveryTurn(line()))
        #expect(!EgressDisclosure.ridesEveryTurn(line(pcc: true)))
        #expect(!EgressDisclosure.ridesEveryTurn(line(web: false)))
    }
}
