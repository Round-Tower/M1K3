//
//  EgressDisclosureTests.swift
//  M1K3ChatTests
//
//  Pins the per-turn "what can leave this device" facts (#482): the persona said
//  "nothing about the user leaves unless they ask", and asked over MCP M1K3
//  repeated it — with web search on by default and Private Cloud Compute a pick.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-04, Confidence 0.85. Prior: Unknown
//

@testable import M1K3Chat
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
        // #485 review: a search query can carry words from a memory, so "on their own".
        #expect(local.contains("memories and documents never leave on their own"))
    }

    @Test("a quotable first-person answer: small models copy a sentence, garble a list")
    func quotable() {
        let text = line()
        #expect(text.hasSuffix("\""))
        #expect(text.contains("answer with this, in your own voice:\n\""))
        #expect(text.contains("not about your wiring"), "Mini gave the leak decline to a privacy question")
        #expect(text.contains("my brain") || text.contains("My brain"))
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

    @Test("it stays short: it rides every turn, Mini's window is 4096 tokens")
    func compact() {
        // ~4 chars a token: the longest combination stays under ~120 tokens.
        #expect(line(web: true, pcc: true, home: false).count < 480)
        #expect(line(web: true, pcc: false, home: true).count < 480) // iOS: no PCC
    }
}
