//
//  HeartbeatComposerTests.swift
//  M1K3HeartbeatTests
//
//  Pins the deterministic digest: the #102 guard in test form. The facts a
//  pulse carries are composed in code from typed snapshots — no retrieval,
//  no tools — so the model's later narrative pass has nothing to invent,
//  only something to tell. Phrasing follows doctrine principle 7: no
//  engineering nouns ("running cool", never "thermal nominal").
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.9 (pure function,
//  behaviour pinned red-first). Prior: none (new file).
//

import Foundation
@testable import M1K3Heartbeat
import Testing

struct HeartbeatComposerTests {
    private func makeContext(
        memory: HeartbeatContext.MemoryActivity? = nil,
        chat: HeartbeatContext.ChatActivity? = nil,
        mcp: HeartbeatContext.MCPActivity? = nil,
        brain: HeartbeatContext.BrainStatus? = nil,
        funFact: HeartbeatContext.FunFact? = nil,
        thermal: ThermalBand = .nominal,
        battery: Int? = nil,
        isCharging: Bool? = nil
    ) -> HeartbeatContext {
        HeartbeatContext(
            date: Date(timeIntervalSince1970: 1_754_480_000),
            device: HeartbeatContext.Device(
                batteryPercent: battery,
                isCharging: isCharging,
                diskFreeGB: 210,
                diskTotalGB: 994,
                uptimeHours: 51,
                thermal: thermal,
                lowPowerMode: false
            ),
            memory: memory,
            chat: chat,
            mcp: mcp,
            brain: brain,
            funFact: funFact,
            earlierPulsesToday: []
        )
    }

    @Test("the digest is deterministic — same context, same bytes")
    func deterministic() {
        let context = makeContext(
            memory: .init(newFactTitles: ["Ardmore round tower"], supersededCount: 1),
            battery: 84, isCharging: false
        )
        #expect(HeartbeatComposer.digest(from: context) == HeartbeatComposer.digest(from: context))
    }

    @Test("no engineering nouns: cool machine, not thermal state")
    func principleSevenPhrasing() {
        let digest = HeartbeatComposer.digest(from: makeContext(thermal: .nominal))
        #expect(digest.contains("running cool"))
        #expect(!digest.lowercased().contains("thermal"))
        #expect(!digest.lowercased().contains("nominal"))
    }

    @Test("a hot machine says so plainly")
    func hotMachine() {
        let digest = HeartbeatComposer.digest(from: makeContext(thermal: .serious))
        #expect(digest.contains("running hot"))
    }

    @Test("battery renders percent and charging state; a desktop omits it")
    func batteryLine() {
        let laptop = HeartbeatComposer.digest(from: makeContext(battery: 84, isCharging: true))
        #expect(laptop.contains("84%"))
        #expect(laptop.contains("charging"))
        let desktop = HeartbeatComposer.digest(from: makeContext(battery: nil))
        #expect(!desktop.contains("%"))
    }

    @Test("one new fact reads singular (pulse 2 said '1 new things')")
    func singularFact() {
        let digest = HeartbeatComposer.digest(from: makeContext(
            memory: .init(newFactTitles: ["Heartbeat ship day"], supersededCount: 1)
        ))
        #expect(digest.contains("Learned 1 new thing:"))
        #expect(!digest.contains("things"))
        #expect(digest.contains("Corrected 1 remembered fact."))
    }

    @Test("memory activity names new facts and counts corrections")
    func memoryActivity() {
        let digest = HeartbeatComposer.digest(from: makeContext(
            memory: .init(
                newFactTitles: ["Ardmore round tower", "Kokoro voice", "Sparrow", "Gecko", "Colobus"],
                supersededCount: 2
            )
        ))
        #expect(digest.contains("5 new"))
        #expect(digest.contains("Ardmore round tower"))
        #expect(digest.contains("and 2 more"))
        #expect(!digest.contains("Gecko"))
        #expect(digest.contains("Corrected 2"))
    }

    @Test("chat, MCP, and brain activity each render when present")
    func activityLines() {
        let digest = HeartbeatComposer.digest(from: makeContext(
            chat: .init(touchedConversationTitles: ["Quantum homework"]),
            mcp: .init(callCount: 4, topTools: ["search_knowledge", "speak"]),
            brain: .init(residentTierName: "Big", downloadingModelName: nil)
        ))
        #expect(digest.contains("Quantum homework"))
        #expect(digest.contains("4 visiting-agent"))
        #expect(digest.contains("search_knowledge"))
        #expect(digest.contains("Big"))
    }

    // MARK: - The 2026-08-30 register fixes (addendum 1–4)

    @Test("the chat line has an actor and it's mutual — a resident says we, a monitor says you were observed")
    func chatLineIsMutual() {
        let digest = HeartbeatComposer.digest(from: makeContext(
            chat: .init(touchedConversationTitles: ["The Ballmer Legacy"])
        ))
        #expect(digest.contains("We talked about 'The Ballmer Legacy'."))
        #expect(!digest.contains("Conversations touched"))
    }

    @Test("the brain line says what the brain IS — an unexplained proper noun becomes a housemate")
    func brainLineExplainsItself() {
        let digest = HeartbeatComposer.digest(from: makeContext(
            brain: .init(residentTierName: "Big", residentTierDescriptor: "the larger brain")
        ))
        #expect(digest.contains("Running on Big, the larger brain."))
        #expect(!digest.contains("is resident"))
    }

    @Test("without a descriptor the brain line still runs, not resides")
    func brainLineNoDescriptor() {
        let digest = HeartbeatComposer.digest(from: makeContext(
            brain: .init(residentTierName: "Lil")
        ))
        #expect(digest.contains("Running on Lil."))
    }

    @Test("the fun fact comes from your documents — the shelf metaphor leaked into the narratives (principle 3)")
    func documentsNotShelf() {
        let digest = HeartbeatComposer.digest(from: makeContext(
            funFact: .init(text: "Round towers were bell houses.", sourceTitle: "Irish towers")
        ))
        #expect(digest.contains("From your documents:"))
        #expect(!digest.contains("shelf"))
    }

    @Test("news leads, ambient follows — the digest's newsworthy half outweighs its stable half")
    func newsLeadsAmbientFollows() {
        let digest = HeartbeatComposer.digest(from: makeContext(
            memory: .init(newFactTitles: ["Ardmore round tower"], supersededCount: 0),
            chat: .init(touchedConversationTitles: ["Quantum homework"])
        ))
        let news = try? #require(digest.range(of: "News:"))
        let ambient = try? #require(digest.range(of: "Ambient:"))
        let learned = try? #require(digest.range(of: "Learned"))
        let machine = try? #require(digest.range(of: "The machine"))
        if let news, let ambient, let learned, let machine {
            #expect(news.lowerBound < learned.lowerBound)
            #expect(learned.lowerBound < ambient.lowerBound)
            #expect(ambient.lowerBound < machine.lowerBound)
        }
    }

    @Test("a quiet digest carries no section headers — nothing to lead with")
    func quietDigestNoHeaders() {
        let digest = HeartbeatComposer.digest(from: makeContext())
        #expect(!digest.contains("News:"))
        #expect(!digest.contains("Ambient:"))
        #expect(digest.contains("quiet stretch"))
    }

    @Test("a quiet stretch says so instead of rendering nothing")
    func quietStretch() {
        let digest = HeartbeatComposer.digest(from: makeContext())
        #expect(digest.contains("quiet stretch"))
    }

    @Test("a fun fact carries its source title")
    func funFact() {
        let digest = HeartbeatComposer.digest(from: makeContext(
            funFact: .init(text: "Round towers were bell houses.", sourceTitle: "Irish towers")
        ))
        #expect(digest.contains("Round towers were bell houses."))
        #expect(digest.contains("Irish towers"))
    }

    @Test("a title-equals-body fun fact drops the duplicate bracket (first live pulse)")
    func funFactTitleIsBody() {
        let digest = HeartbeatComposer.digest(from: makeContext(
            funFact: .init(
                text: "The user is running on a Jetson Orin Nano with 8GB RAM.",
                sourceTitle: "The user is running on a Jetson Orin Nano,…"
            )
        ))
        #expect(digest.contains("Jetson Orin Nano with 8GB RAM."))
        #expect(!digest.contains("["))
    }

    @Test("excerpt cuts at a sentence end, never mid-word")
    func excerptSentenceCut() {
        let text = "Round towers were bell houses. They also served as refuges. Some are twelve floors."
        let excerpt = HeartbeatComposer.excerpt(text, maxLength: 60)
        #expect(excerpt == "Round towers were bell houses. They also served as refuges.")
    }

    @Test("excerpt of a short text is the text itself")
    func excerptShortText() {
        #expect(HeartbeatComposer.excerpt("Short.", maxLength: 60) == "Short.")
    }

    @Test("excerpt without a sentence end trims to a word and adds an ellipsis")
    func excerptNoSentenceEnd() {
        let text = "one two three four five six seven eight nine ten"
        let excerpt = HeartbeatComposer.excerpt(text, maxLength: 20)
        #expect(excerpt == "one two three four…")
    }

    @Test("uptime renders in plain words (#103 review: it was gathered but never told)")
    func uptimeLine() {
        let short = HeartbeatComposer.digest(from: makeContext())
        #expect(short.contains("Up 2 days"))
    }

    @Test("the digest never says Mac — the machine is the noun")
    func machineNotMac() {
        let digest = HeartbeatComposer.digest(from: makeContext(
            memory: .init(newFactTitles: ["A"], supersededCount: 0),
            brain: .init(residentTierName: "Big", downloadingModelName: "Lil")
        ))
        #expect(!digest.contains("Mac"))
    }
}
