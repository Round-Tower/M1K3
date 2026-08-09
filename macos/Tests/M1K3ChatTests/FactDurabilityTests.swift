//
//  FactDurabilityTests.swift
//  M1K3ChatTests
//
//  Every rejection case below is a REAL ROW read out of Kev's live store on
//  2026-08-09 — with third-party names replaced, since this repo is public and
//  the people named in Kev's store never consented to being test fixtures. Every
//  survival case is either a real row that must stay or a
//  fact the store ought to be able to hold. That is the whole design method: the
//  junk was not imagined, it was measured, and the policy is only allowed to be
//  as clever as the evidence.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.9 (fixtures are
//  transcribed from the live audit, not invented). Prior: Unknown
//

@testable import M1K3Chat
import Testing

struct FactDurabilityTests {
    // MARK: - Speech acts: a description of a TURN, not of the person

    @Test("a fact describing what the user asked is not a fact about the user")
    func speechActsAreTransient() {
        for fact in [
            "The user decided to inquire about the weather in Cork.",
            "The user asked for assistance in making the report look more professional.",
            "The user requested a report on WWDC 2026 and its updates.",
            "The user has asked for tips on how to keep curry fresh.",
            "The user asked the assistant to search the internet for the news.",
            "The user decided to respond to all four modules in a single output.",
            "The user has not yet provided the content or message for the page.",
            "The user requested the poem be improved.",
        ] {
            #expect(
                FactDurabilityPolicy.classify(fact) == .transient(.speechAct),
                "should be a speech act: \(fact)"
            )
        }
    }

    @Test("a fact about the conversation itself is not a fact about the user")
    func conversationMetaIsTransient() {
        for fact in [
            "The user is speaking to an assistant.",
            "The user is in a quiet conversation with an assistant.",
            "The conversation mentions a friend's preference and their sense of humour.",
            "The conversation takes place at a bar, as indicated by the background.",
            "The user decided to interact with the assistant for entertainment.",
            "The user has decided to use the AI assistant for research.",
        ] {
            #expect(
                FactDurabilityPolicy.classify(fact) == .transient(.speechAct),
                "should be conversation meta: \(fact)"
            )
        }
    }

    /// The precision/recall trade, written down rather than left implicit.
    ///
    /// "The user is using a computer for the conversation." IS junk, and an
    /// earlier cut caught it with a bare `contains("for the conversation")`.
    /// Review (PR #114) then produced "Kev prepared talking points for the
    /// conversation with his boss" — a durable fact containing the identical
    /// fragment. No pattern separates them; only meaning does.
    ///
    /// A wrongly-dropped fact is invisible and unrecoverable; a surviving junk
    /// row is merely noise, and the sweep can take it. So the junk row wins its
    /// appeal, on purpose, and this test exists so nobody "fixes" it later
    /// without re-reading the trade.
    @Test("an accepted miss: junk survives rather than risk a durable fact")
    func acceptedMisses() {
        #expect(
            FactDurabilityPolicy.classify("The user is using a computer for the conversation.")
                == .durable
        )
        #expect(
            FactDurabilityPolicy.classify("Kev prepared talking points for the conversation with his boss.")
                == .durable
        )
    }

    // MARK: - Moment state: true for minutes, stored for ever

    @Test("a fact true only at this moment is not worth keeping for ever")
    func momentStateIsTransient() {
        for fact in [
            "Kev is currently drinking.",
            "Kev is halfway through a bottle of Red Bull.",
            "The user is currently testing their internet connection.",
            "The user is currently on Thursday, June 16, 2024.",
            "The user is currently in the World Cup.",
            "The user is currently unable to provide a live feed of the match.",
        ] {
            #expect(
                FactDurabilityPolicy.classify(fact) == .transient(.momentState),
                "should be moment state: \(fact)"
            )
        }
    }

    // MARK: - What must survive (the part that makes this safe)

    @Test("standing facts about the person survive untouched")
    func durableFactsSurvive() {
        for fact in [
            // Real rows from the live store that carry the store's actual value.
            "The user is named Kevin Murphy.",
            "Kev is an engineer and AI researcher from Cork.",
            "The user lives in Cork.",
            "Kev is nostalgic about the \"honey in Egyptian tombs\" story.",
            "The user prefers RTÉ for local Cork news and BBC Ireland for national.",
            "Kev made a decision to use Biomock as a tool for their work.",
            "The user has a friend named Aoife.",
            "Kev plans to build a website for a pub in Cork.",
            "Kev prefers serif font themes for web design projects.",
            // The validator's own false-positive guards must not regress here.
            "The user is a research assistant.",
            "The user is a programmer.",
            "The user prefers metric units.",
        ] {
            #expect(
                FactDurabilityPolicy.classify(fact) == .durable,
                "must survive: \(fact)"
            )
        }
    }

    /// The near-misses that decide whether this policy is usable. Each one sits
    /// a single word away from a rejection rule and must NOT trip it.
    @Test("near-miss wordings are not mistaken for transience")
    func nearMissesSurvive() {
        for fact in [
            // "current events" is not "currently" — the classic substring trap.
            "The user is interested in current events.",
            "The user prefers current affairs coverage from RTÉ.",
            // "decided to use X" is a real decision; only "decided to ASK" is a turn.
            "Kev decided to use Hugo as the static site generator.",
            // A recommendation carries content, unlike a question.
            "Kev recommends a WordPress template with a local flavour.",
            "Kev suggests using a static site generator like Hugo.",
            // A durable fact may legitimately name a person who asked something.
            "Kev's sister asks him for tech advice every Christmas.",
            // Review catch (PR #114): a possessive subject is broken by its own
            // apostrophe, but a PRONOUN subject has nothing to break on — so a
            // third party referred to as "they" needs the subject set not to
            // include it. Structurally the same fact as the sister above.
            "Aoife visits every summer; they mentioned wanting to change jobs.",
            // "for the conversation" is a generic fragment, not conversation meta.
            "Kev prepared talking points for the conversation with his boss.",
        ] {
            #expect(
                FactDurabilityPolicy.classify(fact) == .durable,
                "near-miss must survive: \(fact)"
            )
        }
    }

    // MARK: - Wiring

    @Test("the parser drops transient facts alongside the role-fence")
    func parserDropsTransientFacts() {
        let raw = """
        FACT(profile): Kev lives in Cork.
        FACT(episode): The user asked for tips on how to keep curry fresh.
        FACT(note): Kev is currently drinking.
        FACT(profile): The user is named Kevin Murphy.
        """
        #expect(MemoryFactParser.parse(raw).map(\.text) == [
            "Kev lives in Cork.",
            "The user is named Kevin Murphy.",
        ])
    }
}
